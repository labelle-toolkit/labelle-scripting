//! The `labelle` binding table: C-closure shims bridging Lua to the Script
//! Runtime Contract externs, plus the Lua prelude that builds the friendly
//! API on top.
//!
//! Two deliberate layers:
//!   1. `labelle.raw_*` — one shim per contract function, 1:1 and dumb:
//!      strings in, strings out, integer rcs. These stay public so scripts
//!      can always reach the bare contract.
//!   2. src/lua/prelude.lua (embedded below) — Entity wrapper, game.query
//!      iterator, labelle.on/emit/dispatch_inbox event sugar, pure-Lua JSON.
//!      Sugar lives in Lua, not Zig, because it manipulates Lua values —
//!      doing it through the C API would triple the shim count for zero
//!      gain.
//!
//! Buffer sizing: the contract has no two-call sizing on purpose (script
//! payloads are small); the caps below are "generous" per its guidance.
//! Truncation is defined behavior on the contract side (component_get
//! reports 0 when it doesn't fit, query truncates at the last whole id).

const contract = @import("../contract.zig");
const vm_mod = @import("vm.zig");
const c = vm_mod.c;
const Vm = vm_mod.Vm;

/// Serialized-component and polled-event capacity. Components are a
/// handful of fields; 4 KiB gives an order of magnitude of headroom.
const JSON_BUF_CAP = 4096;
/// Query results: at ~7 bytes per id this holds >1000 matches, far past
/// any per-tick script query in practice.
const QUERY_BUF_CAP = 8192;

const prelude_source = @embedFile("prelude.lua");

/// Install the binding table and the prelude into a fresh VM. Must run
/// before any script loads (the prelude also creates `__labelle_scripts`,
/// which `Vm.loadScript` requires). A prelude failure is fatal to setup —
/// unlike a game script, a broken prelude means NO script can work.
pub fn install(vm: Vm) error{PreludeFailed}!void {
    const L = vm.L;
    c.lua_createtable(L, 0, @intCast(shims.len));
    inline for (shims) |shim| {
        c.lua_pushcclosure(L, shim.func, 0);
        c.lua_setfield(L, -2, shim.name);
    }
    c.lua_setglobal(L, "labelle");

    // "@labelle/prelude.lua" so prelude bugs report a recognizable origin
    // instead of an anonymous chunk.
    if (!vm.runChunk("@labelle/prelude.lua", prelude_source)) return error.PreludeFailed;
}

const Shim = struct { name: [*:0]const u8, func: c.CFn };

// Table-driven install: adding a contract function is one extern in
// contract.zig, one shim fn, one row here.
const shims = [_]Shim{
    .{ .name = "raw_entity_create", .func = rawEntityCreate },
    .{ .name = "raw_entity_destroy", .func = rawEntityDestroy },
    .{ .name = "raw_prefab_spawn", .func = rawPrefabSpawn },
    .{ .name = "raw_component_set", .func = rawComponentSet },
    .{ .name = "raw_component_get", .func = rawComponentGet },
    .{ .name = "raw_component_has", .func = rawComponentHas },
    .{ .name = "raw_component_remove", .func = rawComponentRemove },
    .{ .name = "raw_query", .func = rawQuery },
    .{ .name = "raw_event_emit", .func = rawEventEmit },
    .{ .name = "raw_event_subscribe", .func = rawEventSubscribe },
    .{ .name = "raw_event_poll", .func = rawEventPoll },
    .{ .name = "raw_scene_change", .func = rawSceneChange },
    .{ .name = "raw_log", .func = rawLog },
    .{ .name = "raw_time_dt", .func = rawTimeDt },
};

// ── argument helpers ─────────────────────────────────────────────────────

/// Raise a Lua error from inside a shim. lua_error longjmps to the
/// enclosing pcall — the standard C-closure error protocol; our shim frames
/// hold no defers, so the jump is safe. Loud beats silent: a script passing
/// a wrong type gets a traceback pointing at its call site instead of a
/// mysteriously ignored call.
fn argError(L: ?*c.State, comptime msg: []const u8) noreturn {
    _ = c.lua_pushlstring(L, msg.ptr, msg.len);
    _ = c.lua_error(L);
    unreachable;
}

/// Argument `idx` as a string slice (borrowed from the Lua stack — valid
/// for the duration of the shim). Numbers convert per Lua convention.
fn checkString(L: ?*c.State, idx: c_int, comptime what: []const u8) []const u8 {
    var len: usize = 0;
    const p = c.lua_tolstring(L, idx, &len) orelse
        argError(L, "labelle: expected a string for " ++ what);
    return p[0..len];
}

/// Argument `idx` as an entity id. Ids travel as Lua integers (i64) and
/// round-trip to the contract's u64 via bitcast — lossless both ways.
fn checkId(L: ?*c.State, idx: c_int) u64 {
    var isnum: c_int = 0;
    const v = c.lua_tointegerx(L, idx, &isnum);
    if (isnum == 0) argError(L, "labelle: expected an entity id (integer)");
    return @bitCast(v);
}

fn pushId(L: ?*c.State, id: u64) void {
    const v: i64 = @bitCast(id);
    c.lua_pushinteger(L, v);
}

// ── entities ─────────────────────────────────────────────────────────────

fn rawEntityCreate(L: ?*c.State) callconv(.c) c_int {
    pushId(L, contract.labelle_entity_create());
    return 1;
}

fn rawEntityDestroy(L: ?*c.State) callconv(.c) c_int {
    contract.labelle_entity_destroy(checkId(L, 1));
    return 0;
}

fn rawPrefabSpawn(L: ?*c.State) callconv(.c) c_int {
    const name = checkString(L, 1, "prefab name");
    const params = checkString(L, 2, "prefab params json");
    pushId(L, contract.labelle_prefab_spawn(
        name.ptr,
        name.len,
        // len 0 → "spawn at origin" per the contract; pass NULL to make the
        // optionality explicit at the ABI.
        if (params.len == 0) null else params.ptr,
        params.len,
    ));
    return 1;
}

// ── components ───────────────────────────────────────────────────────────

fn rawComponentSet(L: ?*c.State) callconv(.c) c_int {
    const id = checkId(L, 1);
    const name = checkString(L, 2, "component name");
    const json = checkString(L, 3, "component json");
    c.lua_pushinteger(L, contract.labelle_component_set(id, name.ptr, name.len, json.ptr, json.len));
    return 1;
}

fn rawComponentGet(L: ?*c.State) callconv(.c) c_int {
    const id = checkId(L, 1);
    const name = checkString(L, 2, "component name");
    var buf: [JSON_BUF_CAP]u8 = undefined;
    const n = contract.labelle_component_get(id, name.ptr, name.len, &buf, buf.len);
    _ = c.lua_pushlstring(L, &buf, n); // "" = absent (prelude maps to nil)
    return 1;
}

fn rawComponentHas(L: ?*c.State) callconv(.c) c_int {
    const id = checkId(L, 1);
    const name = checkString(L, 2, "component name");
    // The one boolean in the contract — surface it as a Lua boolean rather
    // than a truthy-trap integer (0 is truthy in Lua).
    c.lua_pushboolean(L, @intCast(contract.labelle_component_has(id, name.ptr, name.len)));
    return 1;
}

fn rawComponentRemove(L: ?*c.State) callconv(.c) c_int {
    const id = checkId(L, 1);
    const name = checkString(L, 2, "component name");
    c.lua_pushinteger(L, contract.labelle_component_remove(id, name.ptr, name.len));
    return 1;
}

// ── queries ──────────────────────────────────────────────────────────────

fn rawQuery(L: ?*c.State) callconv(.c) c_int {
    const names_json = checkString(L, 1, "component-names json array");
    var buf: [QUERY_BUF_CAP]u8 = undefined;
    const n = contract.labelle_query(names_json.ptr, names_json.len, &buf, buf.len);
    _ = c.lua_pushlstring(L, &buf, n); // "" = malformed/unbound; "[]" = no match
    return 1;
}

// ── events ───────────────────────────────────────────────────────────────

fn rawEventEmit(L: ?*c.State) callconv(.c) c_int {
    const name = checkString(L, 1, "event name");
    const json = checkString(L, 2, "event payload json");
    c.lua_pushinteger(L, contract.labelle_event_emit(name.ptr, name.len, json.ptr, json.len));
    return 1;
}

fn rawEventSubscribe(L: ?*c.State) callconv(.c) c_int {
    const name = checkString(L, 1, "event name");
    contract.labelle_event_subscribe(name.ptr, name.len);
    return 0;
}

fn rawEventPoll(L: ?*c.State) callconv(.c) c_int {
    var buf: [JSON_BUF_CAP]u8 = undefined;
    const n = contract.labelle_event_poll(&buf, buf.len);
    _ = c.lua_pushlstring(L, &buf, n); // "" = inbox empty (the drain-loop sentinel)
    return 1;
}

// ── scene / log / time ───────────────────────────────────────────────────

fn rawSceneChange(L: ?*c.State) callconv(.c) c_int {
    const name = checkString(L, 1, "scene name");
    c.lua_pushinteger(L, contract.labelle_scene_change(name.ptr, name.len));
    return 1;
}

fn rawLog(L: ?*c.State) callconv(.c) c_int {
    const msg = checkString(L, 1, "log message");
    contract.labelle_log(msg.ptr, msg.len);
    return 0;
}

fn rawTimeDt(L: ?*c.State) callconv(.c) c_int {
    c.lua_pushnumber(L, contract.labelle_time_dt());
    return 1;
}
