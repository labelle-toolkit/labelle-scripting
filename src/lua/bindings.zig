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
//! Buffer sizing: component_get and event_poll share ONE module-lifetime
//! scratch buffer (a userdata anchored in the Lua registry so the GC
//! keeps it alive; `scratch` below caches its pointer). It is GROW-ONLY —
//! the clearRetainingCapacity spirit: sized to the largest payload seen,
//! reused forever after, so steady-state traffic allocates nothing.
//!   - get sizes by the contract itself: component_get returns the bytes
//!     the COMPLETE JSON requires and writes all-or-nothing, so the shim
//!     calls once, and on required > cap grows and retries exactly once.
//!   - poll must NOT be allowed to truncate (a truncated poll CONSUMES
//!     the entry), so the shim probes first — a NULL/cap-0 poll returns
//!     the next entry's size without consuming — grows if needed, then
//!     reads. Two contract calls per event; at game-logic event rates
//!     that is noise, and it is the simplest scheme that can never drop
//!     a byte.
//! The query keeps its own transient path: it returns required-size with
//! a valid truncated prefix, so the shim tries a fixed buffer first and
//! grow-and-retries once via a call-scoped userdata when required > cap —
//! `game.query` always yields ALL matching ids, never a silent prefix.

const contract = @import("../contract.zig");
const vm_mod = @import("vm.zig");
const c = vm_mod.c;
const Vm = vm_mod.Vm;

/// Query results: at ~7 bytes per id this holds >1000 matches, far past
/// any per-tick script query in practice.
const QUERY_BUF_CAP = 8192;

/// Starting capacity of the shared get/poll scratch. Components are a
/// handful of fields; 4 KiB gives an order of magnitude of headroom, so
/// most games never grow it at all.
const SCRATCH_INITIAL_CAP = 4096;

/// Registry key anchoring the scratch userdata (the GC root; the pointer
/// below is just a cache of it).
const SCRATCH_REGISTRY_KEY: [*:0]const u8 = "__labelle_scratch";

/// The shared get/poll scratch: pointer + capacity of the registry-anchored
/// userdata. Module state mirrors the VM singleton (one VM per process);
/// `install` resets it because the block dies with its lua_State.
var scratch: struct { ptr: ?[*]u8, cap: usize } = .{ .ptr = null, .cap = 0 };

/// Monotonic count of scratch (re)allocations — a test seam proving the
/// buffer settles: steady-state polling of even the largest payload must
/// stop bumping this. Never reset (deltas are what tests assert).
pub var scratch_growth_count: usize = 0;

/// Return scratch with room for `needed` bytes, (re)allocating grow-only:
/// a new userdata replaces the registry anchor (the old block becomes
/// garbage) only when the current one is too small. lua_newuserdatauv
/// raises on OOM like any shim error — our frames hold no defers, so the
/// longjmp is safe.
fn ensureScratch(L: ?*c.State, needed: usize) [*]u8 {
    if (scratch.ptr) |p| {
        if (scratch.cap >= needed) return p;
    }
    const cap = @max(needed, SCRATCH_INITIAL_CAP);
    const block: [*]u8 = @ptrCast(c.lua_newuserdatauv(L, cap, 0) orelse
        argError(L, "labelle: scratch allocation failed"));
    c.lua_setfield(L, c.LUA_REGISTRYINDEX, SCRATCH_REGISTRY_KEY);
    scratch = .{ .ptr = block, .cap = cap };
    scratch_growth_count += 1;
    return block;
}

const prelude_source = @embedFile("prelude.lua");

/// Install the binding table and the prelude into a fresh VM. Must run
/// before any script loads (the prelude also creates `__labelle_scripts`,
/// which `Vm.loadScript` requires). A prelude failure is fatal to setup —
/// unlike a game script, a broken prelude means NO script can work.
pub fn install(vm: Vm) error{PreludeFailed}!void {
    const L = vm.L;
    // The previous VM's scratch died with its lua_State; drop the stale
    // cache so the first get/poll in THIS VM re-anchors a fresh block.
    scratch = .{ .ptr = null, .cap = 0 };
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
    // component_get returns the size the COMPLETE JSON requires and
    // writes all-or-nothing, so one call answers "did it fit" and "how
    // big" at once: on required > cap the buffer holds nothing yet —
    // grow the scratch and retry exactly once (nothing can mutate the
    // world between the calls: same tick, same thread).
    var buf = ensureScratch(L, SCRATCH_INITIAL_CAP);
    var n = contract.labelle_component_get(id, name.ptr, name.len, buf, scratch.cap);
    if (n > scratch.cap) {
        buf = ensureScratch(L, n);
        n = contract.labelle_component_get(id, name.ptr, name.len, buf, scratch.cap);
        // Belt: a retry that STILL doesn't fit is impossible (see
        // above); degrade to "absent" rather than push garbage.
        if (n > scratch.cap) n = 0;
    }
    _ = c.lua_pushlstring(L, buf, n); // "" = absent (prelude maps to nil)
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
    // The query is the contract's one snprintf-style op: the return is
    // the size the COMPLETE result requires, however much fit the cap.
    const required = contract.labelle_query(names_json.ptr, names_json.len, &buf, buf.len);
    if (required <= buf.len) {
        _ = c.lua_pushlstring(L, &buf, required); // "" = malformed/unbound; "[]" = no match
        return 1;
    }
    // The id list outgrew the fixed buffer: retry ONCE, right-sized.
    // lua_newuserdatauv is the cleanest allocation inside a shim — a
    // GC-owned block with no allocator plumbing and no free path (it
    // sits below the result string and dies with the call frame; on
    // OOM it raises like any argError). Nothing can mutate the world
    // between the two calls — same tick, same thread, scripts are the
    // only actor — so the retry cannot come back bigger; the @min is
    // pure belt against reading past the block if that invariant ever
    // broke.
    const block: [*]u8 = @ptrCast(c.lua_newuserdatauv(L, required, 0) orelse
        argError(L, "labelle: query retry allocation failed"));
    const n = contract.labelle_query(names_json.ptr, names_json.len, block, required);
    _ = c.lua_pushlstring(L, block, @min(n, required));
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
    // A truncated poll CONSUMES the entry, so never risk one: probe
    // first (NULL/cap-0 returns the NEXT entry's size, no consume),
    // grow the scratch if needed, then do the real read. Two contract
    // calls per event — noise at game-logic event rates, and the
    // simplest scheme that can never drop a byte (see the module doc).
    const next_len = contract.labelle_event_poll(null, 0);
    if (next_len == 0) { // inbox empty — the drain-loop sentinel
        const empty: []const u8 = "";
        _ = c.lua_pushlstring(L, empty.ptr, 0);
        return 1;
    }
    const buf = ensureScratch(L, next_len);
    const n = contract.labelle_event_poll(buf, scratch.cap);
    _ = c.lua_pushlstring(L, buf, @min(n, scratch.cap));
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
