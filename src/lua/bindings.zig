//! The `labelle` binding table: C-closure shims bridging Lua to the Script
//! Runtime Contract externs, plus the Lua prelude that builds the friendly
//! API on top.
//!
//! Two deliberate layers:
//!   1. `labelle.raw_*` — one shim per contract function, 1:1 and dumb:
//!      strings in, strings out, integer rcs. These stay public so scripts
//!      can always reach the bare contract. (Plus one small VM-SIDE
//!      family that never crosses the contract: `raw_gc_*`, the per-tick
//!      GC pacing seams owned by vm.zig.)
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

const std = @import("std");
const contract = @import("../contract.zig");
const id_batch = @import("../id_batch.zig");
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
    .{ .name = "raw_component_set_packed", .func = rawComponentSetPacked },
    .{ .name = "raw_component_get", .func = rawComponentGet },
    .{ .name = "raw_component_get_packed_into", .func = rawComponentGetPackedInto },
    .{ .name = "raw_component_has", .func = rawComponentHas },
    .{ .name = "raw_component_remove", .func = rawComponentRemove },
    .{ .name = "raw_query", .func = rawQuery },
    .{ .name = "raw_batch_get", .func = rawBatchGet },
    .{ .name = "raw_batch_set", .func = rawBatchSet },
    .{ .name = "raw_event_emit", .func = rawEventEmit },
    .{ .name = "raw_event_subscribe", .func = rawEventSubscribe },
    .{ .name = "raw_event_poll", .func = rawEventPoll },
    .{ .name = "raw_scene_change", .func = rawSceneChange },
    .{ .name = "raw_log", .func = rawLog },
    .{ .name = "raw_time_dt", .func = rawTimeDt },
    // VM-side (no contract behind them): per-tick GC pacing, vm.zig's.
    .{ .name = "raw_gc_step", .func = rawGcStep },
    .{ .name = "raw_gc_set_step_budget", .func = rawGcSetStepBudget },
    .{ .name = "raw_gc_stats", .func = rawGcStats },
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

// ── bulk component access (contract v1.3, labelle-scripting#44) ──────────
// The packed per-component codec and the batched whole-query f32 stream.
// Every fast-path extern reference is gated on the COMPTIME
// `contract.host_has_bulk_access` probe: on a pre-v1.3 engine the packed
// shims degrade to their "use the JSON path" sentinel (silent — the
// prelude's JSON leg is the semantic twin) while the batch shims RAISE
// (there is no batch fallback; degrading a whole-query read to nothing
// would be silent data loss).

/// Raise with a runtime-formatted message — `argError`'s formatted twin.
/// An over-long formatted message degrades to a generic refusal rather
/// than failing to raise.
fn raiseFmt(L: ?*c.State, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch
        "labelle: batch refused (message too long to format)";
    _ = c.lua_pushlstring(L, msg.ptr, msg.len);
    _ = c.lua_error(L);
    unreachable;
}

/// The batch f32 stream cannot carry int-typed fields — i64/u64 silently
/// corrupt past f32's 24-bit mantissa, so the host refuses the whole batch
/// (contract v1.3: `(size_t)-2` from batch_get, -2 from batch_set) and the
/// binding surfaces it LOUDLY. Never a silent JSON fallback.
fn raiseBatchIntRefused(L: ?*c.State, names_json: []const u8) noreturn {
    raiseFmt(L, "labelle: batch refused for {s}: a named component has an " ++
        "int-typed field (i64/u64 cannot ride the f32 batch stream) — keep " ++
        "that component on per-entity get/set (the packed codec carries " ++
        "ints losslessly)", .{names_json});
}

const NO_BATCH_HOST_MSG = " — the host engine lacks batch support (script " ++
    "contract v1.3 needs labelle-engine >= 2.6.0); use per-entity get/set " ++
    "on this engine";

/// Clear every existing key of the table at (absolute) index `idx` by
/// assigning nil during a lua_next walk — the documented-safe mutation
/// (existing fields may be set to nil mid-traversal), and the shim twin of
/// json.decode_into's clear-all-then-fill: refilling the SAME keys right
/// after revives their hash slots without a rehash, so a steady-state
/// refill allocates nothing.
fn clearTable(L: ?*c.State, idx: c_int) void {
    c.lua_pushnil(L);
    while (c.lua_next(L, idx) != 0) {
        c.lua_settop(L, -2); // pop the value, keep the key for the walk
        c.lua_pushvalue(L, -1); // duplicate the key for the assignment
        c.lua_pushnil(L);
        c.lua_settable(L, idx); // t[key] = nil (pops the copy + nil)
    }
}

/// `raw_component_get_packed_into(id, name, tbl)` — the packed twin of the
/// prelude's `json.decode_into` leg: decode the host's binary record
/// straight into the caller's REUSED table (stale keys cleared first, the
/// decode_into contract). Returns an integer verdict the prelude branches
/// on:  1 = decoded (component present, packable);  0 = absent (tbl
/// untouched — the JSON get would also report absent);  -1 = take the JSON
/// path (0xFF non-scalar sentinel, or a pre-v1.3 engine — where this
/// comptime-degrades without ever referencing the extern).
///
/// Value parity with the JSON leg: integral f32s land as lua INTEGERS
/// (exactly what the host's "{d}" JSON text decodes to), non-integral as
/// floats; i64/u64 as integers (u64 via the signed 64-bit bitcast, the
/// entity-id rule); bools as booleans.
fn rawComponentGetPackedInto(L: ?*c.State) callconv(.c) c_int {
    if (comptime !contract.host_has_bulk_access) {
        c.lua_pushinteger(L, -1);
        return 1;
    } else {
        const id = checkId(L, 1);
        const name = checkString(L, 2, "component name");
        if (c.lua_type(L, 3) != c.LUA_TTABLE)
            argError(L, "labelle: get(name, into) requires a table to refill");
        var buf = ensureScratch(L, SCRATCH_INITIAL_CAP);
        var n = contract.labelle_component_get_packed(id, name.ptr, name.len, buf, scratch.cap);
        if (n > scratch.cap) {
            buf = ensureScratch(L, n);
            n = contract.labelle_component_get_packed(id, name.ptr, name.len, buf, scratch.cap);
        }
        if (n == 0) {
            c.lua_pushinteger(L, 0); // absent
            return 1;
        }
        if (n > scratch.cap or buf[0] == 0xFF) {
            c.lua_pushinteger(L, -1); // non-scalar component → JSON path
            return 1;
        }
        clearTable(L, 3);
        decodePackedIntoTable(L, 3, buf[0..n]);
        c.lua_pushinteger(L, 1);
        return 1;
    }
}

/// Decode a packed record's fields into the table at `idx`. A malformed
/// record stops early (fields decoded so far stay applied) — the host
/// builds it, so this is belt-and-suspenders.
fn decodePackedIntoTable(L: ?*c.State, idx: c_int, rec: []const u8) void {
    const field_count = rec[0];
    var pos: usize = 1;
    var i: usize = 0;
    while (i < field_count) : (i += 1) {
        if (pos >= rec.len) return;
        const name_len = rec[pos];
        pos += 1;
        if (pos + name_len > rec.len) return;
        const fname = rec[pos..][0..name_len];
        pos += name_len;
        if (pos >= rec.len) return;
        const tag = rec[pos];
        pos += 1;
        _ = c.lua_pushlstring(L, fname.ptr, fname.len);
        switch (tag) {
            0 => { // f32 — integral values land as integers (JSON parity)
                if (pos + 4 > rec.len) {
                    c.lua_settop(L, -2);
                    return;
                }
                const f: f64 = @as(f32, @bitCast(std.mem.readInt(u32, rec[pos..][0..4], .little)));
                pos += 4;
                const max_exact: f64 = 9007199254740992.0; // 2^53 — any integral f32 is far below
                if (@floor(f) == f and @abs(f) <= max_exact) {
                    c.lua_pushinteger(L, @intFromFloat(f));
                } else {
                    c.lua_pushnumber(L, f);
                }
            },
            1 => { // i64
                if (pos + 8 > rec.len) {
                    c.lua_settop(L, -2);
                    return;
                }
                c.lua_pushinteger(L, std.mem.readInt(i64, rec[pos..][0..8], .little));
                pos += 8;
            },
            2 => { // bool
                if (pos + 1 > rec.len) {
                    c.lua_settop(L, -2);
                    return;
                }
                c.lua_pushboolean(L, @intFromBool(rec[pos] != 0));
                pos += 1;
            },
            3 => { // u64 — the signed 64-bit bitcast (the entity-id rule)
                if (pos + 8 > rec.len) {
                    c.lua_settop(L, -2);
                    return;
                }
                c.lua_pushinteger(L, @bitCast(std.mem.readInt(u64, rec[pos..][0..8], .little)));
                pos += 8;
            },
            else => {
                c.lua_settop(L, -2);
                return;
            },
        }
        c.lua_settable(L, idx); // tbl[fname] = value
    }
}

/// `raw_component_set_packed(id, name, tbl)` — the packed write twin: tag
/// each string-keyed field by its LUA runtime type (integer → i64, float
/// → f32 when the value survives the narrow exactly, else the SET-side
/// f64 tag 4 — full precision for float→int targets; boolean) and hand
/// the host the binary record; the host coerces each into the target
/// field's real type (64-bit ints ride the two's-complement bitcast
/// pair). Returns 0 = applied, -1 = "encode JSON and use
/// raw_component_set instead" — on ANY bailout: a non-string key, a
/// non-scalar or non-finite value (the JSON encoder then raises the one
/// canonical error for both routes), an over-wide record, a host refusal
/// (non-scalar/f64 target, unrepresentable value, a pre-tag-4 host
/// handed tag 4 — the JSON fallback carries the f64 faithfully), or a
/// pre-v1.3 engine (where this comptime-degrades without referencing the
/// extern). A finite float beyond ±f32 max is NOT special-cased (#45
/// review): it rides tag 4 like any non-f32-exact float, so a
/// non-packable component or an f64 target still reaches the JSON
/// fallback rather than a spurious raise.
fn rawComponentSetPacked(L: ?*c.State) callconv(.c) c_int {
    if (comptime !contract.host_has_bulk_access) {
        c.lua_pushinteger(L, -1);
        return 1;
    } else {
        const id = checkId(L, 1);
        const name = checkString(L, 2, "component name");
        if (c.lua_type(L, 3) != c.LUA_TTABLE)
            argError(L, "labelle: set_packed requires a component table");
        // Generous stack record: real components sit far under this; a
        // pathological wide table just takes the JSON path. (A `return`
        // mid-walk leaves lua_next's key/value on the stack — fine: a C
        // function's results are the TOP values, the rest is discarded.)
        var rec: [2048]u8 = undefined;
        var w: usize = 1;
        var nfields: usize = 0;
        c.lua_pushnil(L);
        while (c.lua_next(L, 3) != 0) {
            // stack: … key value
            if (c.lua_type(L, -2) != c.LUA_TSTRING) {
                c.lua_pushinteger(L, -1); // non-string key → JSON path raises
                return 1;
            }
            var klen: usize = 0;
            // Safe on the KEY: it is already a string (no in-place
            // number→string conversion that would confuse lua_next).
            const kp = c.lua_tolstring(L, -2, &klen) orelse {
                c.lua_pushinteger(L, -1);
                return 1;
            };
            if (klen > 255 or w + 1 + klen + 9 > rec.len or nfields >= 255) {
                c.lua_pushinteger(L, -1);
                return 1;
            }
            rec[w] = @intCast(klen);
            w += 1;
            @memcpy(rec[w..][0..klen], kp[0..klen]);
            w += klen;
            switch (c.lua_type(L, -1)) {
                c.LUA_TNUMBER => {
                    if (c.lua_isinteger(L, -1) != 0) {
                        rec[w] = 1;
                        w += 1;
                        std.mem.writeInt(i64, rec[w..][0..8], c.lua_tointegerx(L, -1, null), .little);
                        w += 8;
                    } else {
                        const f = c.lua_tonumberx(L, -1, null);
                        // Non-finite PARITY with the JSON route: the
                        // encoder errors ("json.encode: non-finite
                        // number") — never smuggle a NaN/Inf past it.
                        if (!std.math.isFinite(f)) {
                            c.lua_pushinteger(L, -1);
                            return 1;
                        }
                        const f32v: f32 = @floatCast(f);
                        if (@as(f64, f32v) == f) {
                            // Exact in f32 → the compact f32 tag.
                            rec[w] = 0;
                            w += 1;
                            std.mem.writeInt(u32, rec[w..][0..4], @bitCast(f32v), .little);
                            w += 4;
                        } else {
                            // NOT f32-exact — a lossy value (e.g.
                            // 16777217.0 destined for an int field would
                            // round through f32's 24-bit mantissa) OR a
                            // finite one beyond ±f32 range (1e100). BOTH
                            // ride the SET-side f64 tag (4, since v1.3):
                            // full precision to the host, which coerces
                            // per the REAL field type — exact float→int
                            // under its range refusal, and f32-narrowing
                            // (parity with the JSON route) into an f32
                            // field. Deliberately NOT a binding raise (#45
                            // review): the binding cannot know the target
                            // width, so an overflow value must defer to the
                            // host — a host refusal (-1), incl. every
                            // non-packable component, falls through to the
                            // JSON encoder below, which carries the f64
                            // faithfully. (The batch stream, having no f64
                            // tag and no JSON fallback, keeps its
                            // after-narrow refusal.)
                            rec[w] = 4;
                            w += 1;
                            std.mem.writeInt(u64, rec[w..][0..8], @bitCast(f), .little);
                            w += 8;
                        }
                    }
                },
                c.LUA_TBOOLEAN => {
                    rec[w] = 2;
                    w += 1;
                    rec[w] = @intFromBool(c.lua_toboolean(L, -1) != 0);
                    w += 1;
                },
                else => { // string/table/… → JSON path
                    c.lua_pushinteger(L, -1);
                    return 1;
                },
            }
            nfields += 1;
            c.lua_settop(L, -2); // pop the value, keep the key for lua_next
        }
        rec[0] = @intCast(nfields);
        const rc = contract.labelle_component_set_packed(id, name.ptr, name.len, &rec, w);
        // rc != 0: host refused (non-scalar target / unrepresentable
        // value / unknown) — the prelude falls back to the JSON encoder.
        c.lua_pushinteger(L, if (rc == 0) 0 else -1);
        return 1;
    }
}

/// `raw_batch_get(names_json, tbl)` — ONE contract call fills `tbl` with
/// every matching entity's scalar component data as a flat f32 array
/// (1-based), returning the entity COUNT. The host writes
/// `[u32 count][f32 stream]` into the scratch (grow-and-retry on the
/// required-size return); we decode the (n-4)/4 floats into the reused
/// table and TRIM it to exactly that float count — trailing floats of a
/// bigger past tick would otherwise ride into `raw_batch_set` and trip
/// the host's exact-size coupling guard. An int-carrying named component
/// RAISES (host refusal `(size_t)-2`); on a pre-v1.3 engine the call
/// raises "lacks batch support" — there is no batch fallback.
fn rawBatchGet(L: ?*c.State) callconv(.c) c_int {
    // Comptime if/ELSE — not an early raise: only the taken branch is
    // analyzed, so on a pre-v1.3 engine the externs below are never
    // referenced (no link error) and the call raises instead.
    if (comptime !contract.host_has_bulk_access) {
        argError(L, "labelle: batch_get" ++ NO_BATCH_HOST_MSG);
    } else {
        const names = checkString(L, 1, "component-names json array");
        if (c.lua_type(L, 2) != c.LUA_TTABLE)
            argError(L, "labelle: batch_get requires a table to fill");
        // Contract v1.4 default: the id-tagged read (`_batch_get_ids`),
        // stashing ids binding-side and handing the SAME positional
        // `[u32 count][f32 stream]` to this decode loop (unchanged API).
        // v1.3-only host: the positional `_batch_get`.
        const batchGet = if (comptime contract.host_has_id_batch)
            contract.labelle_component_batch_get_ids
        else
            contract.labelle_component_batch_get;
        var buf = ensureScratch(L, SCRATCH_INITIAL_CAP);
        var n = batchGet(names.ptr, names.len, buf, scratch.cap);
        // The refusal sentinel must be checked BEFORE the grow-retry: it
        // is (size_t)-2, which would otherwise read as a required size.
        if (n == contract.BATCH_INT_REFUSED) raiseBatchIntRefused(L, names);
        if (n == 0) {
            c.lua_pushinteger(L, 0); // not bound / malformed
            return 1;
        }
        if (n > scratch.cap) {
            buf = ensureScratch(L, n);
            n = batchGet(names.ptr, names.len, buf, scratch.cap);
            if (n == 0 or n > scratch.cap) { // belt
                c.lua_pushinteger(L, 0);
                return 1;
            }
        }
        // Strip the id column in place (id path only): compact to the
        // positional layout and stash the ids for `raw_batch_set`.
        if (comptime contract.host_has_id_batch) {
            n = id_batch.stripIds(buf[0..scratch.cap], n);
        }
        if (n < 4) {
            c.lua_pushinteger(L, 0);
            return 1;
        }
        const count = std.mem.readInt(u32, buf[0..4], .little);
        const nfloats = (n - 4) / 4;
        var i: usize = 0;
        while (i < nfloats) : (i += 1) {
            const bits = std.mem.readInt(u32, buf[4 + i * 4 ..][0..4], .little);
            c.lua_pushnumber(L, @as(f32, @bitCast(bits)));
            c.lua_rawseti(L, 2, @intCast(i + 1));
        }
        // Trim to exactly the stream's float count (capacity survives).
        var j: u64 = @intCast(nfloats + 1);
        const old_len = c.lua_rawlen(L, 2);
        while (j <= old_len) : (j += 1) {
            c.lua_pushnil(L);
            c.lua_rawseti(L, 2, @intCast(j));
        }
        c.lua_pushinteger(L, count);
        return 1;
    }
}

/// `raw_batch_set(names_json, tbl, count)` — ONE contract call writes the
/// whole swarm back: packs every element of `tbl` (exactly what batch_get
/// filled and trimmed) as raw f32 and hands the pure stream (no header) to
/// the host, which re-queries the same entities and applies positionally.
/// `count` is the caller's entity count (API symmetry); the table length
/// is the authoritative float count. Host refusals RAISE — both mean the
/// write would corrupt data: -2 int-typed field; -1 entity-set drift (the
/// exact-size preflight; nothing was applied — re-run batch_get and
/// recompute). A non-number element (numeric strings included — no silent
/// coercion) and a non-finite number (the json.encode policy, applied at
/// the binding) raise too, naming the element; in every raise NOTHING was
/// handed to the host.
fn rawBatchSet(L: ?*c.State) callconv(.c) c_int {
    // Same comptime if/else gate as rawBatchGet — see the note there.
    if (comptime !contract.host_has_bulk_access) {
        argError(L, "labelle: batch_set" ++ NO_BATCH_HOST_MSG);
    } else {
        const names = checkString(L, 1, "component-names json array");
        if (c.lua_type(L, 2) != c.LUA_TTABLE)
            argError(L, "labelle: batch_set requires the batch_get table");
        // arg 3 (`count`) is accepted for API symmetry; unused here.
        const nfloats: usize = @intCast(c.lua_rawlen(L, 2));
        const bytes = nfloats * 4;
        const buf = ensureScratch(L, @max(bytes, 1));
        var i: usize = 0;
        while (i < nfloats) : (i += 1) {
            _ = c.lua_rawgeti(L, 2, @intCast(i + 1));
            // A REAL number only — lua_tonumberx would silently coerce a
            // numeric string ("42") into the stream, and the contract is
            // loud refusal for non-number elements. The raise names the
            // (1-based) element; nothing was handed to the host.
            if (c.lua_type(L, -1) != c.LUA_TNUMBER) raiseFmt(
                L,
                "labelle: batch_set: array element {d} is not a number — " ++
                    "the f32 stream carries numbers only (nothing was written)",
                .{i + 1},
            );
            const f = c.lua_tonumberx(L, -1, null);
            c.lua_settop(L, -2);
            // Non-finite refusal at the BINDING — the json.encode
            // "non-finite number" policy applied to the stream: NaN/Inf
            // must never ride into component fields. Strict from day one
            // (this API is new in stage 3); ruby's identical gap
            // retrofits the same binding-level check via #45.
            if (!std.math.isFinite(f)) raiseFmt(
                L,
                "labelle: batch_set: non-finite number at element {d} — the " ++
                    "f32 stream refuses NaN/Inf, the json.encode non-finite " ++
                    "policy (nothing was written)",
                .{i + 1},
            );
            const f32v: f32 = @floatCast(f);
            // FINITE-BUT-OVERFLOWING (#45): a finite f64 beyond ±f32 max
            // narrows to inf in the cast above — assert finiteness AFTER
            // the narrow, or the stream smuggles the very values the
            // check above documents as refused.
            if (!std.math.isFinite(f32v)) raiseFmt(
                L,
                "labelle: batch_set: element {d} overflows f32 range (a " ++
                    "finite value narrowed to inf) — the f32 stream refuses " ++
                    "values beyond ±f32 max (nothing was written)",
                .{i + 1},
            );
            std.mem.writeInt(u32, buf[i * 4 ..][0..4], @bitCast(f32v), .little);
        }
        // Contract v1.4 default: `_batch_set_ids` — re-attach the ids
        // stashed by the paired `raw_batch_get` and apply BY ID (a
        // destroy+spawn since the get skips the stale row). v1.3-only
        // host: the positional set.
        const rc = if (comptime contract.host_has_id_batch)
            id_batch.setWithIds(names, buf[0..bytes])
        else
            contract.labelle_component_batch_set(names.ptr, names.len, buf, bytes);
        if (rc == -2) raiseBatchIntRefused(L, names);
        if (rc != 0) raiseFmt(
            L,
            "labelle: batch_set refused for {s}: the entity set changed between " ++
                "batch_get and batch_set (spawn/destroy between the paired calls " ++
                "— the buffer was computed against a stale set; re-run batch_get " ++
                "and recompute), or the names were malformed / the host not bound",
            .{names},
        );
        c.lua_pushinteger(L, 0);
        return 1;
    }
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

// ── gc (VM-side, not contract-side) ──────────────────────────────────────
// The per-tick GC pacing lives entirely in this plugin — vm.zig owns the
// budget and the counters; the host game never sees any of it.

/// One budgeted incremental GC step (vm.zig stepGc; a no-op returning 0
/// when the budget is negative). Returns lua_gc's rc: 1 when this step
/// finished a collection cycle, 0 otherwise, -1 when the collector
/// refused (internally stopped). The prelude's `__tick_controllers`
/// drives this once at the end of every Controller tick.
fn rawGcStep(L: ?*c.State) callconv(.c) c_int {
    c.lua_pushinteger(L, vm_mod.stepGc(L));
    return 1;
}

/// Set the per-tick GC step budget (KB; 0 = the collector's own basic
/// step, negative = disabled) and return the PREVIOUS budget — the
/// save/restore shape tests want. Future plugin params (assembler#591)
/// land on the same vm.zig seam this writes.
fn rawGcSetStepBudget(L: ?*c.State) callconv(.c) c_int {
    var isnum: c_int = 0;
    const v = c.lua_tointegerx(L, 1, &isnum);
    if (isnum == 0) argError(L, "labelle: expected an integer KB budget");
    const budget = std.math.cast(c_int, v) orelse
        argError(L, "labelle: GC step budget out of range");
    c.lua_pushinteger(L, vm_mod.gc_step_budget_kb);
    vm_mod.gc_step_budget_kb = budget;
    return 1;
}

/// (steps, cycles): the monotonic counters of budgeted GC steps driven
/// and of steps that completed a collection cycle. Deltas across a
/// window are the test seam proving the per-tick step really ran — and
/// kept finishing cycles incrementally, no full collect involved.
fn rawGcStats(L: ?*c.State) callconv(.c) c_int {
    c.lua_pushinteger(L, @intCast(vm_mod.gc_step_count));
    c.lua_pushinteger(L, @intCast(vm_mod.gc_cycle_count));
    return 2;
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
