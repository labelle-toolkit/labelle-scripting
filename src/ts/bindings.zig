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
const id_batch = @import("../id_batch.zig");
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
    .{ .name = "raw_component_set_from", .func = rawComponentSetFrom, .arity = 3 },
    .{ .name = "raw_component_get", .func = rawComponentGet, .arity = 2 },
    .{ .name = "raw_component_get_into", .func = rawComponentGetInto, .arity = 3 },
    .{ .name = "raw_component_has", .func = rawComponentHas, .arity = 2 },
    .{ .name = "raw_component_remove", .func = rawComponentRemove, .arity = 2 },
    .{ .name = "raw_query", .func = rawQuery, .arity = 1 },
    .{ .name = "raw_batch_get", .func = rawBatchGet, .arity = 2 },
    .{ .name = "raw_batch_set", .func = rawBatchSet, .arity = 3 },
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

    // ── PACKED fast path (v1.3 hosts only — comptime-gated) ───────────
    // Try the host's binary codec first: it writes the component's scalar
    // fields as a self-describing little-endian record we assign straight
    // onto the object with NO JSON parse (the ruby get_into pattern).
    // Sizing mirrors the JSON get (one call; grow-retry-once on
    // required > cap). Only the first-byte sentinel (0xFF, non-scalar
    // component) or an absent component (0) drops us to JSON. On a
    // pre-v1.3 engine the gate folds this block away entirely (the extern
    // is never referenced → no link error) and every get rides JSON.
    if (comptime contract.host_has_bulk_access) {
        var buf = try io_scratch.ensure(ctx, SCRATCH_INITIAL_CAP);
        var n = contract.labelle_component_get_packed(id, name.s.ptr, name.s.len, buf, io_scratch.cap);
        if (n > io_scratch.cap) {
            buf = try io_scratch.ensure(ctx, n);
            n = contract.labelle_component_get_packed(id, name.s.ptr, name.s.len, buf, io_scratch.cap);
        }
        if (n >= 1 and n <= io_scratch.cap and buf[0] != 0xFF) {
            try decodePackedInto(ctx, buf[0..n], into);
            return c.Value.boolean(true);
        }
        // n == 0 (absent) → the JSON get below also returns absent.
        // buf[0] == 0xFF (non-scalar component) → JSON path decodes it.
    }

    // ── JSON fallback (unchanged) ─────────────────────────────────────
    const json = (try getComponentJson(ctx, id, name.s)) orelse return c.Value.boolean(false);
    try codec.decodeObjectInto(ctx, json, into);
    return c.Value.boolean(true);
}

/// Decode a packed component record (the host's `_get_packed` binary
/// format) straight onto the object: each field record assigns as a
/// property via JS_SetProperty (accessor-backed fields keep working — the
/// decodeObjectInto refill rule). Number materialization matches the JSON
/// decoder exactly: integral values within ±2^53 become Numbers, 64-bit
/// ints beyond become BigInt (the id-bearing range — tag 3 lands on the
/// same unsigned BigInt the raw shims hand out), non-integral f32s become
/// float Numbers. A malformed record stops early (fields decoded so far
/// stay applied) — the host builds it, so this is belt-and-suspenders.
fn decodePackedInto(ctx: ?*c.Context, rec: []const u8, into: c.Value) JsError!void {
    const max_exact: f64 = @floatFromInt(codec.MAX_SAFE_INTEGER);
    if (rec.len < 1) return;
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
        var v: c.Value = undefined;
        switch (tag) {
            0 => { // f32
                if (pos + 4 > rec.len) return;
                const f: f64 = @as(f32, @bitCast(std.mem.readInt(u32, rec[pos..][0..4], .little)));
                pos += 4;
                // Integral f32s materialize as integer Numbers — exactly
                // what the JSON path yields for the host's "{d}" text.
                v = if (@floor(f) == f and @abs(f) <= max_exact)
                    codec.newNumberI64(@intFromFloat(f))
                else
                    c.Value.float(f);
            },
            1 => { // i64
                if (pos + 8 > rec.len) return;
                const iv = std.mem.readInt(i64, rec[pos..][0..8], .little);
                pos += 8;
                if (iv >= -@as(i64, @intCast(codec.MAX_SAFE_INTEGER)) and
                    iv <= @as(i64, @intCast(codec.MAX_SAFE_INTEGER)))
                {
                    v = codec.newNumberI64(iv);
                } else {
                    v = c.JS_NewBigInt64(ctx, iv);
                    if (v.isException()) return error.JsError;
                }
            },
            2 => { // bool
                if (pos + 1 > rec.len) return;
                v = c.Value.boolean(rec[pos] != 0);
                pos += 1;
            },
            3 => { // u64 — unsigned BigInt past 2^53, the id-bearing range
                if (pos + 8 > rec.len) return;
                const uv = std.mem.readInt(u64, rec[pos..][0..8], .little);
                pos += 8;
                if (uv <= codec.MAX_SAFE_INTEGER) {
                    v = codec.newNumberI64(@intCast(uv));
                } else {
                    v = c.JS_NewBigUint64(ctx, uv);
                    if (v.isException()) return error.JsError;
                }
            },
            else => return,
        }
        const key_atom = c.JS_NewAtomLen(ctx, fname.ptr, fname.len);
        if (key_atom == 0) {
            c.JS_FreeValue(ctx, v);
            return error.JsError;
        }
        const rc = c.JS_SetProperty(ctx, into, key_atom, v); // consumes v
        c.JS_FreeAtom(ctx, key_atom);
        if (rc < 0) return error.JsError;
    }
}

fn rawComponentSetFrom(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return componentSetFromImpl(ctx, argv, argc) catch c.Value.exception;
}

/// `raw_component_set_from(id, name, obj)` — the write twin of the packed
/// get_into fast path: tag each own enumerable property by its JS runtime
/// type (int Number → i64, float Number → f32 when the value survives the
/// narrow exactly, else the SET-side f64 tag 4 — full precision for
/// float→int targets; bool; BigInt → i64 via the mod-2^64 wrap — the
/// documented 64-bit two's-complement bitcast pair) and hand the host the
/// binary record; the host coerces each into the target field's real
/// type. Any bailout — a non-scalar value, a non-finite number, an
/// over-wide record, a host refusal (rc != 0: non-scalar/f64 target,
/// out-of-range value, a pre-tag-4 host handed tag 4) — falls back to the
/// JSON encoder, which keeps the exact pre-v1.3 semantics (including the
/// one canonical TypeError for NaN/Inf). A finite float beyond ±f32 max
/// is NOT special-cased here (#45 review): it rides tag 4 like any
/// non-f32-exact float, so a non-packable component or an f64 target
/// still reaches the JSON fallback rather than a spurious throw. Returns
/// the contract rc (0 = ok).
fn componentSetFromImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    const id = try getId(ctx, arg(argv, argc, 0));
    const name = try getStr(ctx, arg(argv, argc, 1), "component name");
    defer c.JS_FreeCString(ctx, name.ptr);
    const obj = arg(argv, argc, 2);
    if (!obj.isObject()) {
        _ = c.JS_ThrowTypeError(ctx, "labelle: set_from requires a component object");
        return error.JsError;
    }

    // ── PACKED fast path (v1.3 hosts only — comptime-gated). NOTE the
    // gate wraps the WHOLE labeled block: a runtime `break :pk` on a
    // comptime-false condition would still ANALYZE the body — and with it
    // the extern reference the gate exists to avoid.
    if (comptime contract.host_has_bulk_access) pk: {
        // Arrays encode as JSON arrays — never a field record (a packed
        // record built from "0"/"1" index keys would silently apply
        // all-defaults where the JSON path refuses the non-object).
        if (c.JS_IsArray(obj)) break :pk;
        var tab: ?[*]c.PropertyEnum = null;
        var count: u32 = 0;
        if (c.JS_GetOwnPropertyNames(ctx, &tab, &count, obj, c.GPN_STRING_MASK | c.GPN_ENUM_ONLY) < 0)
            return error.JsError;
        defer c.JS_FreePropertyEnum(ctx, tab, count);
        if (count > 255) break :pk; // u8 field-count header
        // Generous stack record: real components sit far under this; a
        // pathological wide object just takes the JSON path.
        var rec: [2048]u8 = undefined;
        var w: usize = 1;
        var nfields: u8 = 0;
        for (0..count) |i| {
            const pv = c.JS_GetProperty(ctx, obj, tab.?[i].atom);
            if (pv.isException()) return error.JsError;
            defer c.JS_FreeValue(ctx, pv);
            // JSON.stringify's object rule, mirrored: undefined/function/
            // symbol properties are simply absent (host defaults apply).
            if (pv.isUndefined() or pv.tag == c.TAG_SYMBOL or c.JS_IsFunction(ctx, pv)) continue;
            var nlen: usize = 0;
            const np = c.JS_AtomToCStringLen(ctx, &nlen, tab.?[i].atom) orelse return error.JsError;
            defer c.JS_FreeCString(ctx, np);
            if (nlen > 255 or w + 1 + nlen + 9 > rec.len) break :pk;
            rec[w] = @intCast(nlen);
            w += 1;
            @memcpy(rec[w..][0..nlen], np[0..nlen]);
            w += nlen;
            switch (pv.tag) {
                c.TAG_INT => {
                    rec[w] = 1;
                    w += 1;
                    std.mem.writeInt(i64, rec[w..][0..8], pv.u.int32, .little);
                    w += 8;
                },
                c.TAG_FLOAT64 => {
                    const f = pv.u.float64;
                    // Non-finite PARITY with the JSON route: the encoder
                    // throws ("json_encode: non-finite number"), so the
                    // packed fast path must never smuggle a NaN/Inf into
                    // the host — break to the JSON fallback and let it
                    // raise the one canonical error for both routes.
                    if (std.math.isNan(f) or std.math.isInf(f)) break :pk;
                    const max_exact: f64 = @floatFromInt(codec.MAX_SAFE_INTEGER);
                    if (@floor(f) == f and @abs(f) <= max_exact) {
                        // Integral doubles tag as i64 — the packed twin of
                        // the encoder's integral-when-integral rendering
                        // (JS has one number type; an int-field write must
                        // land exactly, not through f32's 24-bit mantissa).
                        rec[w] = 1;
                        w += 1;
                        std.mem.writeInt(i64, rec[w..][0..8], @intFromFloat(f), .little);
                        w += 8;
                    } else {
                        const f32v: f32 = @floatCast(f);
                        if (@as(f64, f32v) == f) {
                            // Exact in f32 → the compact f32 tag.
                            rec[w] = 0;
                            w += 1;
                            std.mem.writeInt(u32, rec[w..][0..4], @bitCast(f32v), .little);
                            w += 4;
                        } else {
                            // NOT f32-exact — a lossy value (0.1) OR a
                            // finite one beyond ±f32 range (1e100). BOTH
                            // ride the SET-side f64 tag (4, since v1.3):
                            // full precision to the host, which coerces
                            // per the REAL field type — exact into a wide
                            // target, range-refusal into a narrow int, and
                            // f32-narrowing (parity with the JSON route)
                            // into an f32 field. Deliberately NOT a binding
                            // throw (#45 review): the binding cannot know
                            // the target width, and a value beyond f32
                            // range is legitimate for an f64 field, so it
                            // must defer to the host — a host refusal (-1),
                            // incl. every non-packable component, then
                            // falls through to the JSON encoder below,
                            // which carries the f64 faithfully. (The batch
                            // stream, having no f64 tag and no JSON
                            // fallback, keeps its after-narrow refusal.)
                            rec[w] = 4;
                            w += 1;
                            std.mem.writeInt(u64, rec[w..][0..8], @bitCast(f), .little);
                            w += 8;
                        }
                    }
                },
                c.TAG_BOOL => {
                    rec[w] = 2;
                    w += 1;
                    rec[w] = @intFromBool(pv.u.int32 != 0);
                    w += 1;
                },
                c.TAG_BIG_INT, c.TAG_SHORT_BIG_INT => {
                    // Ids: wrap mod 2^64 exactly like the JSON encoder's
                    // unsigned rendering; the i64 tag reaches u64 fields
                    // through the host's two's-complement bitcast pair.
                    var iv: i64 = 0;
                    if (c.JS_ToInt64Ext(ctx, &iv, pv) < 0) return error.JsError;
                    rec[w] = 1;
                    w += 1;
                    std.mem.writeInt(i64, rec[w..][0..8], iv, .little);
                    w += 8;
                },
                else => break :pk, // null/string/object/… → JSON path
            }
            nfields += 1;
        }
        rec[0] = nfields;
        const rc = contract.labelle_component_set_packed(id, name.s.ptr, name.s.len, &rec, w);
        if (rc == 0) return c.Value.int(0);
        // rc != 0: host refused the packed set (non-scalar target /
        // unrepresentable value / unknown) — fall through to JSON.
    }

    // ── JSON fallback: byte-identical to the pre-v1.3 set path ────────
    const json = try codec.encodeToScratch(ctx, obj);
    const rc = contract.labelle_component_set(id, name.s.ptr, name.s.len, json.ptr, json.len);
    return c.Value.int(rc);
}

// ── batched query codec (the whole-query fast path) ──────────────────────

/// The batch f32 stream cannot carry int-typed fields — i64/u64 silently
/// corrupt past f32's 24-bit mantissa, so the host refuses the whole batch
/// (contract v1.3: `(size_t)-2` from batch_get, -2 from batch_set) and the
/// binding surfaces it LOUDLY as a TypeError. Never a silent JSON
/// fallback: coerced-int corruption is exactly what the refusal prevents.
fn throwBatchIntRefused(ctx: ?*c.Context, names_json: []const u8) JsError {
    var buf: [512]u8 = undefined;
    const msg: [:0]const u8 = std.fmt.bufPrintZ(
        &buf,
        "labelle: batch refused for {s}: a named component has an int-typed " ++
            "field (i64/u64 cannot ride the f32 batch stream) — keep that " ++
            "component on per-entity get/set (the packed codec carries ints " ++
            "losslessly)",
        .{names_json},
    ) catch "labelle: batch refused (message too long to format)";
    _ = c.JS_ThrowTypeError(ctx, "%s", msg.ptr);
    return error.JsError;
}

const NO_BATCH_HOST_MSG = " — the host engine lacks batch support (script " ++
    "contract v1.3 needs labelle-engine >= 2.6.0); use per-entity get/set " ++
    "on this engine";

fn rawBatchGet(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return batchGetImpl(ctx, argv, argc) catch c.Value.exception;
}

/// `raw_batch_get(names_json, arr)` — ONE contract call fills `arr` with
/// every matching entity's scalar component data as a flat f32 stream
/// (plain Numbers), returning the entity COUNT. The host writes
/// `[u32 count][f32 stream]` into the io scratch (grow-and-retry on the
/// required-size return); we decode the (n-4)/4 floats into the reused
/// Array and TRIM its length to exactly that float count — trailing floats
/// of a bigger past tick would otherwise ride into `raw_batch_set` and
/// trip the host's exact-size coupling guard. An int-carrying named
/// component THROWS TypeError (host refusal `(size_t)-2`); on a pre-v1.3
/// engine the call throws Error — there is no batch fallback (degrading a
/// whole-query read to nothing would be silent data loss).
fn batchGetImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    // Comptime if/ELSE — not an early throw: only the taken branch is
    // analyzed, so on a pre-v1.3 engine the externs below are never
    // referenced (no link error) and the call throws instead.
    if (comptime !contract.host_has_bulk_access) {
        _ = c.JS_ThrowPlainError(ctx, "labelle: batch_get" ++ NO_BATCH_HOST_MSG);
        return error.JsError;
    } else {
        const names = try getStr(ctx, arg(argv, argc, 0), "component-names json array");
        defer c.JS_FreeCString(ctx, names.ptr);
        const arr = arg(argv, argc, 1);
        if (!c.JS_IsArray(arr)) {
            _ = c.JS_ThrowTypeError(ctx, "labelle: batch_get requires an Array to fill");
            return error.JsError;
        }
        // Contract v1.4 default: the id-tagged read (`_batch_get_ids`),
        // stashing ids binding-side and handing the SAME positional
        // `[u32 count][f32 stream]` to this decode loop (unchanged API).
        // v1.3-only host: the positional `_batch_get`.
        const batchGet = if (comptime contract.host_has_id_batch)
            contract.labelle_component_batch_get_ids
        else
            contract.labelle_component_batch_get;
        var buf = try io_scratch.ensure(ctx, SCRATCH_INITIAL_CAP);
        var n = batchGet(names.s.ptr, names.s.len, buf, io_scratch.cap);
        // The refusal sentinel must be checked BEFORE the grow-retry: it
        // is (size_t)-2, which would otherwise read as a required size. A
        // terminal-failure get never reaches `stripIds`, so it drops any
        // prior stash itself (else stale ids linger for the next set).
        if (n == contract.BATCH_INT_REFUSED) {
            if (comptime contract.host_has_id_batch) id_batch.invalidateStash();
            return throwBatchIntRefused(ctx, names.s);
        }
        if (n == 0) {
            if (comptime contract.host_has_id_batch) id_batch.invalidateStash();
            return c.Value.int(0); // not bound / malformed
        }
        if (n > io_scratch.cap) {
            buf = try io_scratch.ensure(ctx, n);
            n = batchGet(names.s.ptr, names.s.len, buf, io_scratch.cap);
            if (n == 0 or n > io_scratch.cap) {
                if (comptime contract.host_has_id_batch) id_batch.invalidateStash();
                return c.Value.int(0); // belt
            }
        }
        // Strip the id column in place (id path only): compact to the
        // positional layout and stash the ids for `raw_batch_set`.
        if (comptime contract.host_has_id_batch) {
            n = id_batch.stripIds(names.s, buf[0..n], n);
        }
        if (n < 4) return c.Value.int(0);
        const count = std.mem.readInt(u32, buf[0..4], .little);
        const nfloats = (n - 4) / 4;
        var i: usize = 0;
        while (i < nfloats) : (i += 1) {
            const bits = std.mem.readInt(u32, buf[4 + i * 4 ..][0..4], .little);
            const f: f64 = @as(f32, @bitCast(bits));
            if (c.JS_SetPropertyUint32(ctx, arr, @intCast(i), c.Value.float(f)) < 0)
                return error.JsError;
        }
        // Trim to exactly the stream's float count (capacity survives).
        if (c.JS_SetPropertyStr(ctx, arr, "length", c.Value.int(@intCast(nfloats))) < 0)
            return error.JsError;
        return codec.newNumberI64(count);
    }
}

fn rawBatchSet(ctx: ?*c.Context, this: c.Value, argc: c_int, argv: ?[*]const c.Value) callconv(.c) c.Value {
    _ = this;
    return batchSetImpl(ctx, argv, argc) catch c.Value.exception;
}

/// `raw_batch_set(names_json, arr, count)` — ONE contract call writes the
/// whole swarm back: packs every element of `arr` (exactly what batch_get
/// filled and trimmed) as raw f32 and hands the pure stream (no header) to
/// the host, which re-queries the same entities and applies positionally.
/// `count` is the caller's entity count (API symmetry); the array length
/// is the authoritative float count. Host refusals THROW — both mean the
/// write would corrupt data: -2 int-typed field → TypeError; -1 entity-set
/// drift (the exact-size preflight; nothing was applied — re-run batch_get
/// and recompute) → Error. Non-number elements AND non-finite numbers
/// (NaN/Inf — the json_encode non-finite policy, applied at the binding)
/// are a TypeError naming the element; in every throw NOTHING was handed
/// to the host.
fn batchSetImpl(ctx: ?*c.Context, argv: ?[*]const c.Value, argc: c_int) JsError!c.Value {
    // Same comptime if/else gate as batchGetImpl — see the note there.
    if (comptime !contract.host_has_bulk_access) {
        _ = c.JS_ThrowPlainError(ctx, "labelle: batch_set" ++ NO_BATCH_HOST_MSG);
        return error.JsError;
    } else {
        const names = try getStr(ctx, arg(argv, argc, 0), "component-names json array");
        defer c.JS_FreeCString(ctx, names.ptr);
        const arr = arg(argv, argc, 1);
        if (!c.JS_IsArray(arr)) {
            _ = c.JS_ThrowTypeError(ctx, "labelle: batch_set requires the batch_get Array");
            return error.JsError;
        }
        // `count` (arg 2) is accepted for API symmetry; unused here.
        var len: i64 = 0;
        if (c.JS_GetLength(ctx, arr, &len) < 0) return error.JsError;
        const nfloats: usize = @intCast(len);
        const bytes = nfloats * 4;
        const buf = try io_scratch.ensure(ctx, @max(bytes, 1));
        var i: usize = 0;
        while (i < nfloats) : (i += 1) {
            const elem = c.JS_GetPropertyUint32(ctx, arr, @intCast(i));
            if (elem.isException()) return error.JsError;
            defer c.JS_FreeValue(ctx, elem);
            if (!elem.isNumberTag()) {
                var msg_buf: [128]u8 = undefined;
                const msg: [:0]const u8 = std.fmt.bufPrintZ(
                    &msg_buf,
                    "labelle: batch_set: array element {d} is not a number — the " ++
                        "f32 stream carries numbers only (nothing was written)",
                    .{i},
                ) catch unreachable;
                _ = c.JS_ThrowTypeError(ctx, "%s", msg.ptr);
                return error.JsError;
            }
            var f: f64 = 0;
            if (c.JS_ToFloat64(ctx, &f, elem) < 0) return error.JsError;
            // Non-finite refusal at the BINDING — the json_encode
            // "non-finite number" TypeError policy applied to the stream:
            // NaN/Inf must never ride into component fields. Strict from
            // day one (this API is new in stage 3); ruby's identical gap
            // retrofits the same binding-level check via #45.
            if (std.math.isNan(f) or std.math.isInf(f)) {
                var msg_buf: [160]u8 = undefined;
                const msg: [:0]const u8 = std.fmt.bufPrintZ(
                    &msg_buf,
                    "labelle: batch_set: non-finite number at element {d} — the " ++
                        "f32 stream refuses NaN/Inf, the json_encode non-finite " ++
                        "policy (nothing was written)",
                    .{i},
                ) catch unreachable;
                _ = c.JS_ThrowTypeError(ctx, "%s", msg.ptr);
                return error.JsError;
            }
            const f32v: f32 = @floatCast(f);
            // FINITE-BUT-OVERFLOWING (#45): a finite f64 beyond ±f32 max
            // narrows to inf in the cast above — assert finiteness AFTER
            // the narrow, or the stream smuggles the very values the
            // check above documents as refused.
            if (!std.math.isFinite(f32v)) {
                var msg_buf: [192]u8 = undefined;
                const msg: [:0]const u8 = std.fmt.bufPrintZ(
                    &msg_buf,
                    "labelle: batch_set: element {d} overflows f32 range (a " ++
                        "finite value narrowed to inf) — the f32 stream refuses " ++
                        "values beyond ±f32 max (nothing was written)",
                    .{i},
                ) catch unreachable;
                _ = c.JS_ThrowTypeError(ctx, "%s", msg.ptr);
                return error.JsError;
            }
            std.mem.writeInt(u32, buf[i * 4 ..][0..4], @bitCast(f32v), .little);
        }
        // Contract v1.4 default: `_batch_set_ids` — re-attach the ids
        // stashed by the paired `raw_batch_get` and apply BY ID (a
        // destroy+spawn since the get skips the stale row). v1.3-only
        // host: the positional set.
        const rc = if (comptime contract.host_has_id_batch)
            id_batch.setWithIds(names.s, buf[0..bytes])
        else
            contract.labelle_component_batch_set(names.s.ptr, names.s.len, buf, bytes);
        if (rc == -2) return throwBatchIntRefused(ctx, names.s);
        if (rc != 0) {
            var msg_buf: [512]u8 = undefined;
            const msg: [:0]const u8 = std.fmt.bufPrintZ(
                &msg_buf,
                "labelle: batch_set refused for {s}: the entity set changed between " ++
                    "batch_get and batch_set (spawn/destroy between the paired calls " ++
                    "— the buffer was computed against a stale set; re-run batch_get " ++
                    "and recompute), or the names were malformed / the host not bound",
                .{names.s},
            ) catch "labelle: batch_set refused (message too long to format)";
            _ = c.JS_ThrowPlainError(ctx, "%s", msg.ptr);
            return error.JsError;
        }
        return c.Value.int(0);
    }
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
