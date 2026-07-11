//! The `labelle` binding object: C-function shims bridging QuickJS to the
//! Script Runtime Contract externs, plus the JS prelude that builds the
//! friendly API on top.
//!
//! Two deliberate layers, mirroring src/lua/bindings.zig:
//!   1. `labelle.raw_*` — one shim per contract function, 1:1 and dumb.
//!      These stay public so scripts can always reach the bare contract.
//!   2. src/ts/prelude.js (embedded below) — Entity wrapper, game.query,
//!      labelle.on/emit/dispatch_inbox event sugar, component refs,
//!      FrameArray.
//!
//! One deliberate DIVERGENCE from lua (the ruby precedent): the JSON
//! codec lives in Zig — src/ts/json.zig, consumed by the shims below —
//! not in the prelude. Two JavaScript facts force it:
//!   - JSON.parse yields lossy f64 Numbers for every integer token, so a
//!     bit-63 entity id in a payload (u64 unsigned decimal > 2^53) would
//!     round to the wrong entity. The Zig decoder parses integer tokens
//!     with wrapping u64 arithmetic and materializes them as exact
//!     Numbers up to 2^53 and as BigInt beyond — the id-bearing range —
//!     landing bit-exact on the BigInt ids the raw shims hand out.
//!   - JSON.stringify throws on BigInt, so `{ owner: e.id }` payloads
//!     could not be encoded at all. The Zig encoder renders BigInt fields
//!     as unsigned 64-bit decimals (mod 2^64) — ids are the ONLY BigInts
//!     in labelle scripts, and the unsigned rendering is exactly the
//!     contract's wire form, so the lua/ruby `u64str` detour is optional
//!     here (it still ships, for cross-language payload parity).
//!   Everything else keeps JSON.stringify's semantics JS authors expect —
//!   objects/arrays/strings/finite numbers/booleans/null; `undefined` and
//!   functions are SKIPPED as object properties and encode as null in
//!   arrays — plus one strictness upgrade: object keys are emitted SORTED
//!   so hosts and tests can compare payloads byte-for-byte (the every-
//!   backend promise), and a function anywhere else is a loud TypeError.
//!
//! Buffer sizing: two module-lifetime GROW-ONLY scratch buffers (libc
//! heap — the module links libc for the VM anyway; deliberately NOT
//! js_malloc, so scratch growth never shows up in the raw_gc_live
//! allocation counter the steady-state test pins), the
//! clearRetainingCapacity spirit:
//!   - `io_scratch` carries contract payloads (component_get: one call +
//!     grow-retry-once on the required-size return; event_poll: NULL
//!     probe → grow → sized read, so a truncated poll can never consume
//!     an entry; query: one call + grow-retry-once — the ruby scheme);
//!   - `text_scratch` backs the codec's encode output and string
//!     unescaping (json.zig reaches back for it — the two files are one
//!     module split at the codec seam; encode and decode never run
//!     concurrently, so one buffer serves both sides).
//! Both count into `scratch_growth_count`, the settling seam tests assert
//! on (deltas across traffic, not absolute values).
//!
//! Error protocol: QuickJS C functions never longjmp — a failing shim
//! sets a pending exception (JS_Throw*) and returns JS_EXCEPTION. Zig
//! error unions carry that "already thrown" state up through helpers
//! (`error.JsError`), which is also what makes refcount hygiene tractable
//! here: errdefer/defer free every owned JSValue on the failure paths
//! (in Debug, JS_FreeRuntime asserts the heap drained — leaks abort).

const std = @import("std");
const contract = @import("../contract.zig");
const vm_mod = @import("vm.zig");
const codec = @import("json.zig");
const c = vm_mod.c;
const Vm = vm_mod.Vm;

/// Starting capacity of each scratch. Components are a handful of fields;
/// 4 KiB gives an order of magnitude of headroom, so most games never
/// grow either buffer at all.
const SCRATCH_INITIAL_CAP = 4096;

/// "Exception already pending on the context" — the shim unwind signal
/// (defined once, in json.zig).
const JsError = codec.JsError;

/// Monotonic count of scratch (re)allocations across BOTH buffers — the
/// test seam proving they settle. Never reset (tests assert deltas).
pub var scratch_growth_count: usize = 0;

pub const Scratch = struct {
    ptr: ?[*]u8 = null,
    cap: usize = 0,

    /// Grow-only ensure. libc realloc keeps this allocator-plumbing-free
    /// AND invisible to the VM's allocation counters; the buffers live
    /// for the process (the VM is a process singleton).
    pub fn ensure(self: *Scratch, ctx: ?*c.Context, needed: usize) JsError![*]u8 {
        if (self.ptr) |p| {
            if (self.cap >= needed) return p;
        }
        const cap = @max(needed, SCRATCH_INITIAL_CAP);
        const block = std.c.realloc(self.ptr, cap) orelse {
            _ = c.JS_ThrowRangeError(ctx, "labelle: scratch allocation failed");
            return error.JsError;
        };
        self.ptr = @ptrCast(block);
        self.cap = cap;
        scratch_growth_count += 1;
        return self.ptr.?;
    }
};

var io_scratch: Scratch = .{};
/// pub: json.zig's encoder/unescaper writes here (see the module doc).
pub var text_scratch: Scratch = .{};

const prelude_source: [:0]const u8 = @embedFile("prelude.js");

/// Install the binding object and the prelude into a fresh VM. Must run
/// before any script loads (the prelude also creates `__labelle_scripts`,
/// which `Vm.loadScript` requires). A prelude failure is fatal to setup —
/// unlike a game script, a broken prelude means NO script can work.
pub fn install(vm: Vm) error{PreludeFailed}!void {
    const ctx = vm.ctx;
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    const labelle_obj = c.JS_NewObject(ctx);
    if (labelle_obj.isException()) return error.PreludeFailed;
    var attached = false;
    defer if (!attached) c.JS_FreeValue(ctx, labelle_obj);

    inline for (shims) |shim| {
        const fn_val = c.JS_NewCFunction2(ctx, shim.func, shim.name, shim.arity, 0, 0);
        if (fn_val.isException()) return error.PreludeFailed;
        // SetPropertyStr consumes fn_val, success or not.
        if (c.JS_SetPropertyStr(ctx, labelle_obj, shim.name, fn_val) < 0) return error.PreludeFailed;
    }
    // Consumes labelle_obj (even on error) — hence the `attached` latch.
    attached = true;
    if (c.JS_SetPropertyStr(ctx, global, "labelle", labelle_obj) < 0) return error.PreludeFailed;

    // "labelle/prelude.js" so prelude bugs report a recognizable origin.
    if (!vm.runChunk("labelle/prelude.js", prelude_source)) return error.PreludeFailed;
}

const Shim = struct { name: [*:0]const u8, func: *const c.CFunction, arity: c_int };

// Table-driven install: adding a contract function is one extern in
// contract.zig, one shim fn, one row here.
const shims = [_]Shim{
    .{ .name = "raw_entity_create", .func = rawEntityCreate, .arity = 0 },
    .{ .name = "raw_entity_destroy", .func = rawEntityDestroy, .arity = 1 },
    .{ .name = "raw_prefab_spawn", .func = rawPrefabSpawn, .arity = 2 },
    .{ .name = "raw_component_set", .func = rawComponentSet, .arity = 3 },
    .{ .name = "raw_component_get", .func = rawComponentGet, .arity = 2 },
    .{ .name = "raw_component_get_into", .func = rawComponentGetInto, .arity = 3 },
    .{ .name = "raw_component_has", .func = rawComponentHas, .arity = 2 },
    .{ .name = "raw_component_remove", .func = rawComponentRemove, .arity = 2 },
    .{ .name = "raw_query", .func = rawQuery, .arity = 1 },
    .{ .name = "raw_event_emit", .func = rawEventEmit, .arity = 2 },
    .{ .name = "raw_event_subscribe", .func = rawEventSubscribe, .arity = 1 },
    .{ .name = "raw_event_poll", .func = rawEventPoll, .arity = 0 },
    .{ .name = "raw_scene_change", .func = rawSceneChange, .arity = 1 },
    .{ .name = "raw_log", .func = rawLog, .arity = 1 },
    .{ .name = "raw_time_dt", .func = rawTimeDt, .arity = 0 },
    .{ .name = "raw_u64str", .func = rawU64Str, .arity = 1 },
    .{ .name = "json_encode", .func = jsonEncodeShim, .arity = 1 },
    .{ .name = "json_decode", .func = jsonDecodeShim, .arity = 1 },
    // Diagnostics (the steady-state allocation test seams; harmless for
    // games — raw_gc_live walks the heap, so keep it out of hot loops).
    .{ .name = "raw_gc", .func = rawGc, .arity = 0 },
    .{ .name = "raw_gc_live", .func = rawGcLive, .arity = 0 },
};

// ── argument helpers ─────────────────────────────────────────────────────

/// Argument `i`, or undefined when the caller passed fewer (QuickJS pads
/// nothing for generic C functions — missing args are simply absent).
fn arg(argv: ?[*]const c.Value, argc: c_int, i: usize) c.Value {
    const count: usize = if (argc > 0) @intCast(argc) else 0;
    if (argv == null or i >= count) return c.Value.undefined_;
    return argv.?[i];
}

/// Entity ids: BigInt (the canonical form the shims hand out — created
/// via JS_NewBigUint64, so ids read as their true UNSIGNED value in
/// scripts) or Number (host-sent small ids in payloads). JS_ToInt64Ext
/// wraps BigInts mod 2^64 and truncates Numbers — both land on the same
/// bitcast the contract's u64 expects. Everything else (strings included:
/// ToNumber("9223372036854775809") would round through a float) is a loud
/// TypeError.
fn getId(ctx: ?*c.Context, v: c.Value) JsError!u64 {
    if (!v.isNumberTag() and !v.isBigInt()) {
        _ = c.JS_ThrowTypeError(ctx, "labelle: expected an entity id (BigInt or number)");
        return error.JsError;
    }
    var i: i64 = 0;
    if (c.JS_ToInt64Ext(ctx, &i, v) < 0) return error.JsError;
    return @bitCast(i);
}

/// A string argument as borrowed UTF-8 bytes. Caller must
/// JS_FreeCString(ptr) after use. Non-strings do NOT convert — loud beats
/// a stringified accident.
const Str = struct { ptr: [*:0]const u8, s: []const u8 };

fn getStr(ctx: ?*c.Context, v: c.Value, comptime what: [:0]const u8) JsError!Str {
    if (!v.isString()) {
        _ = c.JS_ThrowTypeError(ctx, "labelle: expected a string for " ++ what);
        return error.JsError;
    }
    var len: usize = 0;
    const p = c.JS_ToCStringLen2(ctx, &len, v, false) orelse return error.JsError;
    return .{ .ptr = p, .s = p[0..len] };
}

// ── entities ─────────────────────────────────────────────────────────────

fn rawEntityCreate(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    _ = argc;
    _ = argv;
    return c.JS_NewBigUint64(ctx, contract.labelle_entity_create());
}

fn rawEntityDestroy(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    const id = getId(ctx, arg(argv, argc, 0)) catch return c.Value.exception;
    contract.labelle_entity_destroy(id);
    return c.Value.undefined_;
}

fn rawPrefabSpawn(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return prefabSpawnImpl(ctx, argv, argc) catch c.Value.exception;
}

fn prefabSpawnImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const name = try getStr(ctx, arg(argv, argc, 0), "prefab name");
    defer c.JS_FreeCString(ctx, name.ptr);
    const params = try getStr(ctx, arg(argv, argc, 1), "prefab params json");
    defer c.JS_FreeCString(ctx, params.ptr);
    const id = contract.labelle_prefab_spawn(
        name.s.ptr,
        name.s.len,
        // len 0 → "spawn at origin" per the contract; pass NULL to make
        // the optionality explicit at the ABI.
        if (params.s.len == 0) null else params.s.ptr,
        params.s.len,
    );
    return c.JS_NewBigUint64(ctx, id);
}

// ── components ───────────────────────────────────────────────────────────

fn rawComponentSet(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return componentSetImpl(ctx, argv, argc) catch c.Value.exception;
}

fn componentSetImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const id = try getId(ctx, arg(argv, argc, 0));
    const name = try getStr(ctx, arg(argv, argc, 1), "component name");
    defer c.JS_FreeCString(ctx, name.ptr);
    const json = try getStr(ctx, arg(argv, argc, 2), "component json");
    defer c.JS_FreeCString(ctx, json.ptr);
    const rc = contract.labelle_component_set(id, name.s.ptr, name.s.len, json.s.ptr, json.s.len);
    return c.Value.int(rc);
}

/// The component's stored JSON into the io scratch, honoring the
/// required-size contract: one call, and on required > cap grow the
/// scratch and retry exactly once (all-or-nothing writes — nothing landed
/// on the short call; nothing can mutate the world between the two calls:
/// same tick, same thread). Returns null when absent.
fn getComponentJson(ctx: ?*c.Context, id: u64, name: []const u8) JsError!?[]const u8 {
    var buf = try io_scratch.ensure(ctx, SCRATCH_INITIAL_CAP);
    var n = contract.labelle_component_get(id, name.ptr, name.len, buf, io_scratch.cap);
    if (n == 0) return null;
    if (n > io_scratch.cap) {
        buf = try io_scratch.ensure(ctx, n);
        n = contract.labelle_component_get(id, name.ptr, name.len, buf, io_scratch.cap);
        // Belt: a retry that STILL doesn't fit is impossible; degrade to
        // "absent" rather than hand garbage to the decoder.
        if (n == 0 or n > io_scratch.cap) return null;
    }
    return buf[0..n];
}

fn rawComponentGet(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return componentGetImpl(ctx, argv, argc) catch c.Value.exception;
}

fn componentGetImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const id = try getId(ctx, arg(argv, argc, 0));
    const name = try getStr(ctx, arg(argv, argc, 1), "component name");
    defer c.JS_FreeCString(ctx, name.ptr);
    const json = (try getComponentJson(ctx, id, name.s)) orelse return c.Value.null_;
    return c.JS_NewStringLen(ctx, json.ptr, json.len);
}

/// `raw_component_get_into(id, name, into)` — decode the component's JSON
/// DIRECTLY onto the existing object: each top-level key is assigned as a
/// property (fields absent from the JSON keep their previous value, the
/// ruby get_into REFILL semantics). Scalar fields cross as immediates —
/// zero JS allocation, the engine of the `e.get(name, into)` hot-loop
/// idiom. Returns true when the component existed.
fn rawComponentGetInto(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return componentGetIntoImpl(ctx, argv, argc) catch c.Value.exception;
}

fn componentGetIntoImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const id = try getId(ctx, arg(argv, argc, 0));
    const name = try getStr(ctx, arg(argv, argc, 1), "component name");
    defer c.JS_FreeCString(ctx, name.ptr);
    const into = arg(argv, argc, 2);
    if (!into.isObject()) {
        _ = c.JS_ThrowTypeError(ctx, "labelle: get(name, into) requires an object to refill");
        return error.JsError;
    }
    const json = (try getComponentJson(ctx, id, name.s)) orelse return c.Value.boolean(false);
    try codec.decodeObjectInto(ctx, json, into);
    return c.Value.boolean(true);
}

fn rawComponentHas(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return componentHasImpl(ctx, argv, argc) catch c.Value.exception;
}

fn componentHasImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const id = try getId(ctx, arg(argv, argc, 0));
    const name = try getStr(ctx, arg(argv, argc, 1), "component name");
    defer c.JS_FreeCString(ctx, name.ptr);
    return c.Value.boolean(contract.labelle_component_has(id, name.s.ptr, name.s.len) == 1);
}

fn rawComponentRemove(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return componentRemoveImpl(ctx, argv, argc) catch c.Value.exception;
}

fn componentRemoveImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const id = try getId(ctx, arg(argv, argc, 0));
    const name = try getStr(ctx, arg(argv, argc, 1), "component name");
    defer c.JS_FreeCString(ctx, name.ptr);
    return c.Value.int(contract.labelle_component_remove(id, name.s.ptr, name.s.len));
}

// ── queries ──────────────────────────────────────────────────────────────

/// `raw_query(names_json)` → Array of entity-id BigInts. The id parse
/// happens HERE with wrapping u64 arithmetic (JSON.parse would round
/// bit-63 ids through f64), each id materialized via JS_NewBigUint64 so
/// scripts see the true unsigned value. One contract call, and on
/// required > cap (snprintf-style sizing) grow + retry once — the caller
/// always sees ALL matching ids, never a silent prefix.
fn rawQuery(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return queryImpl(ctx, argv, argc) catch c.Value.exception;
}

fn queryImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const names = try getStr(ctx, arg(argv, argc, 0), "component-names json array");
    defer c.JS_FreeCString(ctx, names.ptr);
    var buf = try io_scratch.ensure(ctx, SCRATCH_INITIAL_CAP);
    var n = contract.labelle_query(names.s.ptr, names.s.len, buf, io_scratch.cap);
    if (n > io_scratch.cap) {
        buf = try io_scratch.ensure(ctx, n);
        n = contract.labelle_query(names.s.ptr, names.s.len, buf, io_scratch.cap);
        if (n > io_scratch.cap) n = io_scratch.cap; // belt (see lua shim)
    }
    const text = buf[0..n];

    const arr = c.JS_NewArray(ctx);
    if (arr.isException()) return error.JsError;
    errdefer c.JS_FreeValue(ctx, arr);
    var idx: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b >= '0' and b <= '9') {
            var id: u64 = 0;
            while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
                id = id *% 10 +% (text[i] - '0');
            }
            const idv = c.JS_NewBigUint64(ctx, id);
            if (idv.isException()) return error.JsError;
            if (c.JS_SetPropertyUint32(ctx, arr, idx, idv) < 0) return error.JsError; // consumes idv
            idx += 1;
        } else {
            i += 1; // brackets, commas, whitespace
        }
    }
    return arr;
}

// ── events ───────────────────────────────────────────────────────────────

fn rawEventEmit(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return eventEmitImpl(ctx, argv, argc) catch c.Value.exception;
}

fn eventEmitImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const name = try getStr(ctx, arg(argv, argc, 0), "event name");
    defer c.JS_FreeCString(ctx, name.ptr);
    const json = try getStr(ctx, arg(argv, argc, 1), "event payload json");
    defer c.JS_FreeCString(ctx, json.ptr);
    return c.Value.int(contract.labelle_event_emit(name.s.ptr, name.s.len, json.s.ptr, json.s.len));
}

fn rawEventSubscribe(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return eventSubscribeImpl(ctx, argv, argc) catch c.Value.exception;
}

fn eventSubscribeImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const name = try getStr(ctx, arg(argv, argc, 0), "event name");
    defer c.JS_FreeCString(ctx, name.ptr);
    contract.labelle_event_subscribe(name.s.ptr, name.s.len);
    return c.Value.undefined_;
}

/// `raw_event_poll()` → `[name_string, payload]` or null when the inbox
/// is empty. A truncated poll CONSUMES the entry, so never risk one:
/// probe first (NULL/cap-0 returns the NEXT entry's size, no consume),
/// grow the scratch if needed, then do the real read (the lua shim's
/// scheme). The payload arrives already DECODED — the prelude's dispatch
/// hands it straight to handlers, and integer id fidelity rides the Zig
/// decoder (see the module doc).
fn rawEventPoll(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    _ = argc;
    _ = argv;
    return eventPollImpl(ctx) catch c.Value.exception;
}

fn eventPollImpl(ctx: ?*c.Context) JsError!c.Value {
    const next_len = contract.labelle_event_poll(null, 0);
    if (next_len == 0) return c.Value.null_; // inbox empty — the drain sentinel
    const buf = try io_scratch.ensure(ctx, next_len);
    const n = contract.labelle_event_poll(buf, io_scratch.cap);
    const entry = buf[0..@min(n, io_scratch.cap)];

    // "<name> <json>" — name is the token before the first space.
    const space = std.mem.indexOfScalar(u8, entry, ' ') orelse entry.len;
    const name = entry[0..space];
    const payload_text = std.mem.trim(u8, entry[@min(space + 1, entry.len)..], " ");

    const pair = c.JS_NewArray(ctx);
    if (pair.isException()) return error.JsError;
    errdefer c.JS_FreeValue(ctx, pair);

    const name_val = c.JS_NewStringLen(ctx, name.ptr, name.len);
    if (name_val.isException()) return error.JsError;
    if (c.JS_SetPropertyUint32(ctx, pair, 0, name_val) < 0) return error.JsError;

    var payload: c.Value = undefined;
    if (payload_text.len == 0) {
        // Empty payload = "all defaults": hand handlers an empty object,
        // the same shape a "{}" payload decodes to.
        payload = c.JS_NewObject(ctx);
        if (payload.isException()) return error.JsError;
    } else {
        payload = try codec.decodeDocument(ctx, payload_text);
    }
    if (c.JS_SetPropertyUint32(ctx, pair, 1, payload) < 0) return error.JsError;
    return pair;
}

// ── scene / log / time ───────────────────────────────────────────────────

fn rawSceneChange(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return sceneChangeImpl(ctx, argv, argc) catch c.Value.exception;
}

fn sceneChangeImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const name = try getStr(ctx, arg(argv, argc, 0), "scene name");
    defer c.JS_FreeCString(ctx, name.ptr);
    return c.Value.int(contract.labelle_scene_change(name.s.ptr, name.s.len));
}

fn rawLog(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return logImpl(ctx, argv, argc) catch c.Value.exception;
}

fn logImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const msg = try getStr(ctx, arg(argv, argc, 0), "log message");
    defer c.JS_FreeCString(ctx, msg.ptr);
    contract.labelle_log(msg.s.ptr, msg.s.len);
    return c.Value.undefined_;
}

fn rawTimeDt(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = ctx;
    _ = this;
    _ = argc;
    _ = argv;
    return c.Value.float(contract.labelle_time_dt());
}

// ── u64 helper + json entry points ───────────────────────────────────────

/// `raw_u64str(id)` — the id's UNSIGNED decimal rendering as a string.
/// BigInt ids already print unsigned in JS (they carry the true u64
/// value), so unlike lua/ruby this is not load-bearing for display — it
/// ships for cross-language payload parity ({ owner: labelle.u64str(id) }
/// reads identically in every backend's docs) and for Number-held ids.
fn rawU64Str(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return u64StrImpl(ctx, argv, argc) catch c.Value.exception;
}

fn u64StrImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const id = try getId(ctx, arg(argv, argc, 0));
    var buf: [20]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("{d}", .{id}) catch unreachable;
    const s = w.buffered();
    return c.JS_NewStringLen(ctx, s.ptr, s.len);
}

fn jsonEncodeShim(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return jsonEncodeImpl(ctx, argv, argc) catch c.Value.exception;
}

fn jsonEncodeImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const json = try codec.encodeToScratch(ctx, arg(argv, argc, 0));
    return c.JS_NewStringLen(ctx, json.ptr, json.len);
}

fn jsonDecodeShim(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return jsonDecodeImpl(ctx, argv, argc) catch c.Value.exception;
}

fn jsonDecodeImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const text = try getStr(ctx, arg(argv, argc, 0), "json text");
    defer c.JS_FreeCString(ctx, text.ptr);
    return codec.decodeDocument(ctx, text.s);
}

// ── gc diagnostics (test seams) ──────────────────────────────────────────

fn rawGc(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    _ = argc;
    _ = argv;
    c.JS_RunGC(c.JS_GetRuntime(ctx));
    return c.Value.undefined_;
}

/// Live malloc count (JS_ComputeMemoryUsage.malloc_count) — the strict
/// allocation counter behind the steady-state test: QuickJS refcounting
/// frees acyclic garbage at the last reference, so a net-zero tick keeps
/// this EXACTLY constant (the refcount-world equivalent of mruby's
/// disabled-GC live-object count).
fn rawGcLive(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    _ = argc;
    _ = argv;
    var usage: c.MemoryUsage = undefined;
    c.JS_ComputeMemoryUsage(c.JS_GetRuntime(ctx), &usage);
    return codec.newNumberI64(usage.malloc_count);
}
