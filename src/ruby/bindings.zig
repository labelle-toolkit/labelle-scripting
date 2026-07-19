//! The `Labelle` binding module: C-function shims bridging mruby to the
//! Script Runtime Contract externs, plus the ruby prelude that builds the
//! friendly API on top.
//!
//! Two deliberate layers, mirroring src/lua/bindings.zig:
//!   1. `Labelle.raw_*` — one shim per contract function, 1:1 and dumb.
//!      These stay public so scripts can always reach the bare contract.
//!   2. src/ruby/prelude.rb (embedded below) — Entity wrapper,
//!      Component.ref, Controller, FrameArray, Labelle.on/emit/each sugar.
//!
//! One deliberate DIVERGENCE from lua: the JSON codec lives HERE, in Zig,
//! not in the prelude. Two mruby facts force it:
//!   - mruby integer arithmetic RAISES RangeError on overflow (no
//!     wrapping), so the lua prelude's wrapping `acc*10+digit` u64-id
//!     parse cannot be written in ruby at all — the bitcast arithmetic
//!     must live on the Zig side (u64str, integer-token decode, query-id
//!     parse all included);
//!   - decoding straight into mrb_values lets `raw_component_get_into`
//!     refill a Struct-backed component instance with ZERO ruby-object
//!     churn for scalar fields (integers, floats, bools and symbols are
//!     immediate under MRB_NO_BOXING), which is the engine of the
//!     `e.get(Hunger, into: @h)` zero-alloc pattern.
//! The lua `labelle.array` empty-[] disambiguation has no ruby
//! equivalent to ship: Hash and Array are distinct types, so `{}` vs `[]`
//! is native — the codec simply preserves it.
//!
//! Buffer sizing: two module-lifetime GROW-ONLY scratch buffers (libc
//! heap — the module links libc for the VM anyway), the
//! clearRetainingCapacity spirit:
//!   - `io_scratch` carries contract payloads (component_get: one call +
//!     grow-retry-once on the required-size return; event_poll: NULL
//!     probe → grow → sized read, so a truncated poll can never consume
//!     an entry; query: one call + grow-retry-once — unlike lua there is
//!     no fixed first-try buffer, the shared scratch serves all three);
//!   - `text_scratch` backs JSON encode output and string unescaping
//!     (encode and decode never run concurrently, so one buffer serves
//!     both sides).
//! Both count into `scratch_growth_count`, the settling seam tests
//! assert on (deltas across traffic, not absolute values).

const std = @import("std");
const contract = @import("../contract.zig");
const vm_mod = @import("vm.zig");
const c = vm_mod.c;
const Vm = vm_mod.Vm;

/// Starting capacity of each scratch. Components are a handful of fields;
/// 4 KiB gives an order of magnitude of headroom, so most games never
/// grow either buffer at all.
const SCRATCH_INITIAL_CAP = 4096;

/// Struct-backed component views cap their field count (Component.ref
/// with more is a design smell, not a use case).
const MAX_REF_FIELDS = 32;

/// Object keys per JSON object during encode (sorting buffer).
const MAX_OBJECT_KEYS = 64;

/// Monotonic count of scratch (re)allocations across BOTH buffers — the
/// test seam proving they settle. Never reset (tests assert deltas).
pub var scratch_growth_count: usize = 0;

const Scratch = struct {
    ptr: ?[*]u8 = null,
    cap: usize = 0,

    /// Grow-only ensure. libc realloc keeps this allocator-plumbing-free;
    /// the buffers live for the process (the VM is a process singleton).
    fn ensure(self: *Scratch, mrb: ?*c.State, needed: usize) [*]u8 {
        if (self.ptr) |p| {
            if (self.cap >= needed) return p;
        }
        const cap = @max(needed, SCRATCH_INITIAL_CAP);
        const block = std.c.realloc(self.ptr, cap) orelse
            raiseError(mrb, "RuntimeError", "labelle: scratch allocation failed");
        self.ptr = @ptrCast(block);
        self.cap = cap;
        scratch_growth_count += 1;
        return self.ptr.?;
    }

    fn slice(self: *Scratch) []u8 {
        return if (self.ptr) |p| p[0..self.cap] else &.{};
    }
};

var io_scratch: Scratch = .{};
var text_scratch: Scratch = .{};

/// Per-VM interned symbols the hot paths reuse (reset by `install` — syms
/// are per-mrb_state). `[]`/`[]=` drive Struct field access in the
/// into/from fast paths.
var syms: struct { aref: c.Sym, aset: c.Sym } = undefined;

const prelude_source = @embedFile("prelude.rb");

/// Install the binding functions and the prelude into a fresh VM. Must
/// run before any script loads (the prelude also defines the harvest and
/// controller machinery Vm.loadScript depends on). A prelude failure is
/// fatal to setup — unlike a game script, a broken prelude means NO
/// script can work.
pub fn install(vm: Vm) error{PreludeFailed}!void {
    const mrb = vm.mrb;
    syms = .{
        .aref = c.mrb_intern(mrb, "[]", 2),
        .aset = c.mrb_intern(mrb, "[]=", 3),
    };
    inline for (shims) |shim| {
        c.mrb_define_module_function(mrb, vm.labelle_module, shim.name, shim.func, shim.aspec);
    }
    if (!vm.runChunk("labelle/prelude.rb", prelude_source)) return error.PreludeFailed;
}

const Shim = struct { name: [*:0]const u8, func: c.Func, aspec: c.Aspec };

/// MRB_ARGS_REQ(n) — mruby.h encodes required argc at bit 18.
fn argsReq(n: u5) c.Aspec {
    return @as(c.Aspec, n) << 18;
}

// Table-driven install: adding a contract function is one extern in
// contract.zig, one shim fn, one row here.
const shims = [_]Shim{
    .{ .name = "raw_entity_create", .func = rawEntityCreate, .aspec = argsReq(0) },
    .{ .name = "raw_entity_destroy", .func = rawEntityDestroy, .aspec = argsReq(1) },
    .{ .name = "raw_prefab_spawn", .func = rawPrefabSpawn, .aspec = argsReq(2) },
    .{ .name = "raw_component_set", .func = rawComponentSet, .aspec = argsReq(3) },
    .{ .name = "raw_component_get", .func = rawComponentGet, .aspec = argsReq(2) },
    .{ .name = "raw_component_get_into", .func = rawComponentGetInto, .aspec = argsReq(4) },
    .{ .name = "raw_component_set_from", .func = rawComponentSetFrom, .aspec = argsReq(4) },
    .{ .name = "raw_component_has", .func = rawComponentHas, .aspec = argsReq(2) },
    .{ .name = "raw_component_remove", .func = rawComponentRemove, .aspec = argsReq(2) },
    .{ .name = "raw_query", .func = rawQuery, .aspec = argsReq(1) },
    .{ .name = "raw_batch_get", .func = rawBatchGet, .aspec = argsReq(2) },
    .{ .name = "raw_batch_set", .func = rawBatchSet, .aspec = argsReq(3) },
    .{ .name = "raw_event_emit", .func = rawEventEmit, .aspec = argsReq(2) },
    .{ .name = "raw_event_subscribe", .func = rawEventSubscribe, .aspec = argsReq(1) },
    .{ .name = "raw_event_poll", .func = rawEventPoll, .aspec = argsReq(0) },
    .{ .name = "raw_scene_change", .func = rawSceneChange, .aspec = argsReq(1) },
    .{ .name = "raw_log", .func = rawLog, .aspec = argsReq(1) },
    .{ .name = "raw_time_dt", .func = rawTimeDt, .aspec = argsReq(0) },
    .{ .name = "raw_u64str", .func = rawU64Str, .aspec = argsReq(1) },
    .{ .name = "json_encode", .func = jsonEncodeShim, .aspec = argsReq(1) },
    .{ .name = "json_decode", .func = jsonDecodeShim, .aspec = argsReq(1) },
    // Diagnostics (the zero-alloc test seams; harmless for games).
    .{ .name = "raw_gc_arena", .func = rawGcArena, .aspec = argsReq(0) },
    .{ .name = "raw_gc_live", .func = rawGcLive, .aspec = argsReq(0) },
    .{ .name = "raw_gc_disable", .func = rawGcDisable, .aspec = argsReq(1) },
};

// ── argument helpers ─────────────────────────────────────────────────────

/// Raise a ruby exception from inside a shim. mrb_raise longjmps to the
/// enclosing VM frame — the standard C-function error protocol; our shim
/// frames hold no defers, so the jump is safe. Loud beats silent.
fn raiseError(mrb: ?*c.State, comptime class: []const u8, comptime msg: [:0]const u8) noreturn {
    const cls_sym = c.mrb_intern(mrb, class.ptr, class.len);
    c.mrb_raise(mrb, c.mrb_exc_get_id(mrb, cls_sym), msg.ptr);
}

/// A symbol's name COPIED into `storage` (bump-allocated at `*used`).
/// The copy is load-bearing: mruby packs short symbol names inline in the
/// symbol id and mrb_sym_name_len unpacks them into a single per-state
/// buffer — the pointer it returns is only valid until the NEXT call, so
/// collecting several names (hash keys, struct fields) without copying
/// yields N aliases of the last name.
fn copySymName(mrb: ?*c.State, sym: c.Sym, storage: []u8, used: *usize) []const u8 {
    var nl: c.Int = 0;
    const np = c.mrb_sym_name_len(mrb, sym, &nl) orelse
        raiseError(mrb, "TypeError", "labelle: unnameable symbol");
    const name = np[0..@intCast(nl)];
    if (used.* + name.len > storage.len)
        raiseError(mrb, "ArgumentError", "labelle: object key names too large");
    const dst = storage[used.*..][0..name.len];
    @memcpy(dst, name);
    used.* += name.len;
    return dst;
}

/// One "s" argument: borrowed (ptr, len) of a ruby String (numbers and
/// symbols do NOT convert — mrb_get_args raises TypeError, the loud path).
fn getStr(mrb: ?*c.State) []const u8 {
    var p: [*]const u8 = undefined;
    var l: c.Int = undefined;
    _ = c.mrb_get_args(mrb, "s", &p, &l);
    return p[0..@intCast(l)];
}

fn getIntStr(mrb: ?*c.State) struct { i: c.Int, s: []const u8 } {
    var i: c.Int = undefined;
    var p: [*]const u8 = undefined;
    var l: c.Int = undefined;
    _ = c.mrb_get_args(mrb, "is", &i, &p, &l);
    return .{ .i = i, .s = p[0..@intCast(l)] };
}

/// Entity ids travel as ruby Integers (mrb_int = i64 under MRB_INT64) and
/// round-trip to the contract's u64 via bitcast — lossless both ways.
fn idFromInt(i: c.Int) u64 {
    return @bitCast(i);
}

// ── entities ─────────────────────────────────────────────────────────────

fn rawEntityCreate(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = mrb;
    _ = self;
    return c.Value.int(@bitCast(contract.labelle_entity_create()));
}

fn rawEntityDestroy(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    var i: c.Int = undefined;
    _ = c.mrb_get_args(mrb, "i", &i);
    contract.labelle_entity_destroy(idFromInt(i));
    return c.Value.nil();
}

fn rawPrefabSpawn(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    var np: [*]const u8 = undefined;
    var nl: c.Int = undefined;
    var pp: [*]const u8 = undefined;
    var pl: c.Int = undefined;
    _ = c.mrb_get_args(mrb, "ss", &np, &nl, &pp, &pl);
    const params_len: usize = @intCast(pl);
    const id = contract.labelle_prefab_spawn(
        np,
        @intCast(nl),
        // len 0 → "spawn at origin" per the contract; pass NULL to make
        // the optionality explicit at the ABI.
        if (params_len == 0) null else pp,
        params_len,
    );
    return c.Value.int(@bitCast(id));
}

// ── components ───────────────────────────────────────────────────────────

fn rawComponentSet(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    var i: c.Int = undefined;
    var np: [*]const u8 = undefined;
    var nl: c.Int = undefined;
    var jp: [*]const u8 = undefined;
    var jl: c.Int = undefined;
    _ = c.mrb_get_args(mrb, "iss", &i, &np, &nl, &jp, &jl);
    const rc = contract.labelle_component_set(idFromInt(i), np, @intCast(nl), jp, @intCast(jl));
    return c.Value.int(rc);
}

/// The component's stored JSON into the io scratch, honoring the
/// required-size contract: one call, and on required > cap grow the
/// scratch and retry exactly once (all-or-nothing writes — nothing landed
/// on the short call; nothing can mutate the world between the two calls:
/// same tick, same thread). Returns null when absent.
fn getComponentJson(mrb: ?*c.State, id: u64, name: []const u8) ?[]const u8 {
    var buf = io_scratch.ensure(mrb, SCRATCH_INITIAL_CAP);
    var n = contract.labelle_component_get(id, name.ptr, name.len, buf, io_scratch.cap);
    if (n == 0) return null;
    if (n > io_scratch.cap) {
        buf = io_scratch.ensure(mrb, n);
        n = contract.labelle_component_get(id, name.ptr, name.len, buf, io_scratch.cap);
        // Belt: a retry that STILL doesn't fit is impossible; degrade to
        // "absent" rather than hand garbage to the decoder.
        if (n == 0 or n > io_scratch.cap) return null;
    }
    return buf[0..n];
}

fn rawComponentGet(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const a = getIntStr(mrb);
    const json = getComponentJson(mrb, idFromInt(a.i), a.s) orelse return c.Value.nil();
    return c.mrb_str_new(mrb, json.ptr, @intCast(json.len));
}

fn rawComponentHas(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const a = getIntStr(mrb);
    return c.Value.boolean(contract.labelle_component_has(idFromInt(a.i), a.s.ptr, a.s.len) == 1);
}

fn rawComponentRemove(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const a = getIntStr(mrb);
    return c.Value.int(contract.labelle_component_remove(idFromInt(a.i), a.s.ptr, a.s.len));
}

// ── Struct-backed fast paths (the `into:` pattern) ───────────────────────

const IntoArgs = struct { id: u64, name: []const u8, inst: c.Value, fields: c.Value };

fn getIntoArgs(mrb: ?*c.State) IntoArgs {
    var i: c.Int = undefined;
    var np: [*]const u8 = undefined;
    var nl: c.Int = undefined;
    var inst: c.Value = undefined;
    var fields: c.Value = undefined;
    _ = c.mrb_get_args(mrb, "isoA", &i, &np, &nl, &inst, &fields);
    const nfields = c.labelle_mrb_ary_len(fields);
    // Defense in depth: the prelude's __view rejects over-wide views at
    // CONSTRUCTION (and the declare runner at build time), so a prelude-
    // built view can never trip this — it guards direct raw_* callers
    // with hand-built field arrays. Message digits ride the constant.
    if (nfields > MAX_REF_FIELDS)
        raiseError(mrb, "ArgumentError", "labelle: Component.ref supports at most " ++
            std.fmt.comptimePrint("{d}", .{MAX_REF_FIELDS}) ++ " fields");
    return .{ .id = idFromInt(i), .name = np[0..@intCast(nl)], .inst = inst, .fields = fields };
}

/// `raw_component_get_into(id, name, instance, fields)` — decode the
/// component's JSON DIRECTLY into the existing Struct instance: for each
/// top-level key that names a declared field, `instance[idx] = value`.
/// Scalar fields (numbers, bools, nil) cross as immediates — zero ruby
/// allocation; string/nested fields allocate their values only. Unknown
/// keys are skipped without materializing anything; fields absent from
/// the JSON keep their previous value. Returns true when the component
/// existed.
fn rawComponentGetInto(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const a = getIntoArgs(mrb);

    // Pre-intern the field symbols once per call (interning an existing
    // symbol is a lookup, not an allocation — these settle at warm-up).
    // Shared by BOTH the packed fast path and the JSON fallback.
    var field_syms: [MAX_REF_FIELDS]c.Sym = undefined;
    const nfields: usize = @intCast(c.labelle_mrb_ary_len(a.fields));
    for (0..nfields) |fi| {
        const fv = c.mrb_ary_entry(a.fields, @intCast(fi));
        if (fv.tt != .symbol)
            raiseError(mrb, "TypeError", "labelle: component fields must be symbols");
        field_syms[fi] = fv.value.sym;
    }

    // ── PACKED fast path (v1.3 hosts only — comptime-gated) ───────────
    // Try the host's binary codec first: it writes the component's scalar
    // fields as a self-describing little-endian record we decode straight
    // into the instance with NO JSON parse. Sizing mirrors the JSON get
    // (one call; grow-retry-once on required > cap). Only the first-byte
    // sentinel (0xFF) or an absent component (0) drops us to JSON. On a
    // pre-v1.3 engine the gate folds this block away entirely (the extern
    // is never referenced → no link error) and every get rides JSON.
    if (comptime contract.host_has_bulk_access) {
        var buf = io_scratch.ensure(mrb, SCRATCH_INITIAL_CAP);
        var n = contract.labelle_component_get_packed(a.id, a.name.ptr, a.name.len, buf, io_scratch.cap);
        if (n > io_scratch.cap) {
            buf = io_scratch.ensure(mrb, n);
            n = contract.labelle_component_get_packed(a.id, a.name.ptr, a.name.len, buf, io_scratch.cap);
        }
        if (n >= 1 and n <= io_scratch.cap and buf[0] != 0xFF) {
            decodePackedInto(mrb, buf[0..n], a.inst, field_syms[0..nfields]);
            return c.Value.boolean(true);
        }
        // n == 0 (absent) → JSON get also returns absent (false).
        // buf[0] == 0xFF (non-scalar component) → JSON path decodes it.
    }

    // ── JSON fallback (unchanged) ─────────────────────────────────────
    const json = getComponentJson(mrb, a.id, a.name) orelse return c.Value.boolean(false);

    var p = Parser{ .mrb = mrb, .text = json };
    p.skipWs();
    if (p.peek() != '{')
        raiseError(mrb, "RuntimeError", "labelle: component JSON is not an object");
    p.pos += 1;
    p.skipWs();
    if (p.peek() == '}') return c.Value.boolean(true);
    while (true) {
        const key = p.parseKey();
        const key_sym = c.mrb_intern(mrb, key.ptr, key.len);
        var matched: ?usize = null;
        for (field_syms[0..nfields], 0..) |fs, fi| {
            if (fs == key_sym) {
                matched = fi;
                break;
            }
        }
        if (matched) |fi| {
            const v = p.parseValue();
            var args = [_]c.Value{ c.Value.int(@intCast(fi)), v };
            _ = c.mrb_funcall_argv(mrb, a.inst, syms.aset, 2, &args);
        } else {
            p.skipValue();
        }
        p.skipWs();
        switch (p.next()) {
            ',' => p.skipWs(),
            '}' => break,
            else => raiseError(mrb, "RuntimeError", "labelle: malformed component JSON"),
        }
    }
    return c.Value.boolean(true);
}

/// Decode a packed component record (the host's `_get_packed` binary
/// format) straight into the Struct instance: for each field record whose
/// name matches a declared view field, `instance[idx] = <mrb value>`. Tags
/// map to immediates (f32→Float, i64/u64→Integer, bool→true/false) so a
/// scalar refill allocates nothing. A malformed record stops early (the
/// fields decoded so far stay applied) — the host builds it, so this is
/// belt-and-suspenders. `field_syms` are the pre-interned view fields.
fn decodePackedInto(mrb: ?*c.State, rec: []const u8, inst: c.Value, field_syms: []const c.Sym) void {
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
                const bits = std.mem.readInt(u32, rec[pos..][0..4], .little);
                pos += 4;
                v = c.Value.float(@as(f32, @bitCast(bits)));
            },
            1 => { // i64
                if (pos + 8 > rec.len) return;
                v = c.Value.int(std.mem.readInt(i64, rec[pos..][0..8], .little));
                pos += 8;
            },
            2 => { // bool
                if (pos + 1 > rec.len) return;
                v = c.Value.boolean(rec[pos] != 0);
                pos += 1;
            },
            3 => { // u64 (bitcast to the signed id representation ruby uses)
                if (pos + 8 > rec.len) return;
                v = c.Value.int(@bitCast(std.mem.readInt(u64, rec[pos..][0..8], .little)));
                pos += 8;
            },
            else => return,
        }
        // Match the field name to a declared view field, assign in place.
        const key_sym = c.mrb_intern(mrb, fname.ptr, fname.len);
        for (field_syms, 0..) |fs, idx| {
            if (fs == key_sym) {
                var args = [_]c.Value{ c.Value.int(@intCast(idx)), v };
                _ = c.mrb_funcall_argv(mrb, inst, syms.aset, 2, &args);
                break;
            }
        }
    }
}

/// `raw_component_set_from(id, name, instance, fields)` — encode the
/// Struct instance's fields as a sorted-key JSON object (field values
/// read via `instance[idx]`, no intermediate Hash) and hand it to the
/// contract. Returns the contract rc (0 = ok).
fn rawComponentSetFrom(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const a = getIntoArgs(mrb);
    const nfields: usize = @intCast(c.labelle_mrb_ary_len(a.fields));

    // ── PACKED fast path (v1.3 hosts only — comptime-gated) ───────────
    // Build the binary record from the view's fields — tag each by its
    // RUBY value type (Float→f32, Integer→i64, true/false→bool). The host
    // coerces each into the target struct field's real type. A field whose
    // ruby value isn't a scalar (nil/String/Array/…), an over-long name, or
    // a record that would overflow the local buffer aborts the fast path
    // (`break :pk`) and we fall through to the JSON encoder below. A host
    // rc != 0 (component not packable there, or a value its target field
    // cannot represent — out-of-range int, NaN into an int) does the same:
    // the JSON path surfaces the value faithfully. On a pre-v1.3 engine
    // the gate folds the whole block away (extern never referenced).
    // NOTE the gate wraps the WHOLE labeled block: a runtime `break :pk`
    // on a comptime-false condition would still ANALYZE the body — and
    // with it the extern reference the gate exists to avoid.
    if (comptime contract.host_has_bulk_access) pk: {
        // Generous stack record: real components sit far under this; a
        // pathological wide view just takes the JSON path.
        var rec: [2048]u8 = undefined;
        var w: usize = 0;
        rec[w] = @intCast(nfields);
        w += 1;
        for (0..nfields) |fi| {
            const fv = c.mrb_ary_entry(a.fields, @intCast(fi));
            if (fv.tt != .symbol)
                raiseError(mrb, "TypeError", "labelle: component fields must be symbols");
            // Name — mrb_sym_name_len's pointer is valid only until the
            // NEXT mrb call, so copy it in immediately.
            var nl: c.Int = 0;
            const np = c.mrb_sym_name_len(mrb, fv.value.sym, &nl) orelse
                raiseError(mrb, "TypeError", "labelle: unnameable symbol");
            const nlen: usize = @intCast(nl);
            if (nlen > 255 or w + 1 + nlen + 9 > rec.len) break :pk;
            rec[w] = @intCast(nlen);
            w += 1;
            @memcpy(rec[w..][0..nlen], np[0..nlen]);
            w += nlen;
            // Value via instance[idx].
            var idx = [_]c.Value{c.Value.int(@intCast(fi))};
            const v = c.mrb_funcall_argv(mrb, a.inst, syms.aref, 1, &idx);
            switch (v.tt) {
                .float => {
                    // Non-finite PARITY with the JSON route: `encodeValue`
                    // raises ("json_encode: non-finite number"), so the
                    // packed fast path must never smuggle a NaN/Inf into
                    // the host that the JSON encoder would refuse — break
                    // to the JSON fallback and let encodeValue raise the
                    // one canonical error for both routes. (A FINITE
                    // out-of-f32-range f64 is fine either way: @floatCast
                    // saturates — a defined, non-trapping conversion — and
                    // the JSON route's f64 text parses to the same
                    // saturated f32 in the host field.)
                    if (!std.math.isFinite(v.value.f)) break :pk;
                    rec[w] = 0;
                    w += 1;
                    const f: f32 = @floatCast(v.value.f);
                    std.mem.writeInt(u32, rec[w..][0..4], @bitCast(f), .little);
                    w += 4;
                },
                .integer => {
                    rec[w] = 1;
                    w += 1;
                    std.mem.writeInt(i64, rec[w..][0..8], v.value.i, .little);
                    w += 8;
                },
                .true => {
                    rec[w] = 2;
                    w += 1;
                    rec[w] = 1;
                    w += 1;
                },
                .false => {
                    // nil (tt .false, i == 0) is not a bool — let JSON
                    // encode it as null.
                    if (v.isNil()) break :pk;
                    rec[w] = 2;
                    w += 1;
                    rec[w] = 0;
                    w += 1;
                },
                else => break :pk, // String/Array/Hash/… → JSON path
            }
        }
        const rc = contract.labelle_component_set_packed(a.id, a.name.ptr, a.name.len, &rec, w);
        if (rc == 0) return c.Value.int(0);
        // rc != 0: host refused the packed set (non-scalar target /
        // unknown) — fall through to the JSON encoder.
    }

    // ── JSON fallback (unchanged) ─────────────────────────────────────
    // Field names + declared order index, then insertion-sort by name so
    // the encoding is deterministic (the codec's promise; lua sorts too).
    // Names are COPIED out: mruby packs short symbol names inline and
    // mrb_sym_name_len unpacks them into ONE per-state buffer, so the
    // returned pointers alias across calls.
    var name_storage: [1024]u8 = undefined;
    var names: [MAX_REF_FIELDS][]const u8 = undefined;
    var order: [MAX_REF_FIELDS]usize = undefined;
    var used: usize = 0;
    for (0..nfields) |fi| {
        const fv = c.mrb_ary_entry(a.fields, @intCast(fi));
        if (fv.tt != .symbol)
            raiseError(mrb, "TypeError", "labelle: component fields must be symbols");
        names[fi] = copySymName(mrb, fv.value.sym, &name_storage, &used);
        order[fi] = fi;
    }
    var i: usize = 1;
    while (i < nfields) : (i += 1) {
        const oi = order[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, names[order[j - 1]], names[oi]) == .gt) : (j -= 1) {
            order[j] = order[j - 1];
        }
        order[j] = oi;
    }

    var out = Out{ .mrb = mrb };
    out.byte('{');
    for (order[0..nfields], 0..) |fi, k| {
        if (k > 0) out.byte(',');
        out.jsonString(names[fi]);
        out.byte(':');
        var idx = [_]c.Value{c.Value.int(@intCast(fi))};
        const v = c.mrb_funcall_argv(mrb, a.inst, syms.aref, 1, &idx);
        encodeValue(mrb, v, &out, 0);
    }
    out.byte('}');
    const json = out.slice();
    const rc = contract.labelle_component_set(a.id, a.name.ptr, a.name.len, json.ptr, json.len);
    return c.Value.int(rc);
}

// ── queries ──────────────────────────────────────────────────────────────

/// `raw_query(names_json)` → ruby Array of entity-id Integers. The id
/// parse happens HERE with wrapping u64 arithmetic + i64 bitcast (ruby
/// integer arithmetic raises on overflow, so bit-63 ids can only be
/// assembled on this side of the boundary). One contract call, and on
/// required > cap (snprintf-style sizing) grow + retry once — the caller
/// always sees ALL matching ids, never a silent prefix.
fn rawQuery(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const names = getStr(mrb);
    var buf = io_scratch.ensure(mrb, SCRATCH_INITIAL_CAP);
    var n = contract.labelle_query(names.ptr, names.len, buf, io_scratch.cap);
    if (n > io_scratch.cap) {
        buf = io_scratch.ensure(mrb, n);
        n = contract.labelle_query(names.ptr, names.len, buf, io_scratch.cap);
        if (n > io_scratch.cap) n = io_scratch.cap; // belt (see lua shim)
    }
    const text = buf[0..n];
    const ary = c.mrb_ary_new_capa(mrb, 8);
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b >= '0' and b <= '9') {
            var id: u64 = 0;
            while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
                id = id *% 10 +% (text[i] - '0');
            }
            c.mrb_ary_push(mrb, ary, c.Value.int(@bitCast(id)));
        } else {
            i += 1; // brackets, commas, whitespace
        }
    }
    return ary;
}

// ── batched query codec (the whole-query fast path) ──────────────────────

/// Raise with a runtime-formatted message — `raiseError`'s formatted twin
/// (that one is comptime-message only). An over-long formatted message
/// degrades to a generic refusal rather than failing to raise.
fn raiseFmt(
    mrb: ?*c.State,
    comptime class: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) noreturn {
    var buf: [512]u8 = undefined;
    const msg: [:0]const u8 = std.fmt.bufPrintZ(&buf, fmt, args) catch
        "labelle: batch refused (message too long to format)";
    const cls_sym = c.mrb_intern(mrb, class.ptr, class.len);
    c.mrb_raise(mrb, c.mrb_exc_get_id(mrb, cls_sym), msg.ptr);
}

/// The batch f32 stream cannot carry int-typed fields — i64/u64 silently
/// corrupt past f32's 24-bit mantissa, so the host refuses the whole
/// batch (contract v1.3: `(size_t)-2` from batch_get, -2 from batch_set)
/// and the binding surfaces it LOUDLY. Never a silent JSON fallback:
/// coerced-int corruption is exactly what the refusal exists to prevent.
fn raiseBatchIntRefused(mrb: ?*c.State, names_json: []const u8) noreturn {
    raiseFmt(
        mrb,
        "ArgumentError",
        "labelle: batch refused for {s}: a named component has an int-typed " ++
            "field (i64/u64 cannot ride the f32 batch stream) — keep that " ++
            "component on per-entity get/set (the packed codec carries ints " ++
            "losslessly)",
        .{names_json},
    );
}

/// `raw_batch_get(names_json, out_array)` — ONE contract call fills
/// `out_array` with every matching entity's scalar component data as a flat
/// f32 stream, returning the entity COUNT (Integer). The host writes
/// `[u32 count][f32 stream]` into the io scratch (grow-and-retry on the
/// required-size return, like rawQuery); we read the count header, then
/// decode the (n-4)/4 floats straight into the reused Array via mrb_ary_set
/// (elements 0..M-1, growing it once then reusing across ticks), and TRIM
/// the Array to exactly that float count (mrb_ary_resize keeps capacity, so
/// reuse still costs nothing) — the trailing floats of a bigger past tick
/// would otherwise ride into `raw_batch_set` and trip the host's exact-size
/// coupling guard. Floats cross as immediates — the only per-tick
/// allocation is the Array's own backing growth, amortized to zero once
/// warm. An int-carrying named component RAISES ArgumentError (host
/// refusal `(size_t)-2` — see raiseBatchIntRefused).
fn rawBatchGet(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    // Comptime if/ELSE — not an early raise: only the taken branch is
    // analyzed, so on a pre-v1.3 engine the extern below is never
    // referenced (no link error) and the call raises instead. There is
    // no batch fallback — degrading a whole-query read to nothing would
    // be silent data loss, so the absence must be loud.
    if (comptime !contract.host_has_bulk_access) {
        raiseError(mrb, "RuntimeError", "labelle: batch_get — the host engine lacks " ++
            "batch support (script contract v1.3 needs labelle-engine >= 2.6.0); " ++
            "use per-entity get/set on this engine");
    } else {
        var np: [*]const u8 = undefined;
        var nl: c.Int = undefined;
        var arr: c.Value = undefined;
        _ = c.mrb_get_args(mrb, "sA", &np, &nl, &arr);
        const names = np[0..@intCast(nl)];

        var buf = io_scratch.ensure(mrb, SCRATCH_INITIAL_CAP);
        var n = contract.labelle_component_batch_get(names.ptr, names.len, buf, io_scratch.cap);
        // The refusal sentinel must be checked BEFORE the grow-retry: it is
        // (size_t)-2, which would otherwise read as a required size.
        if (n == contract.BATCH_INT_REFUSED) raiseBatchIntRefused(mrb, names);
        if (n == 0) return c.Value.int(0); // not bound / malformed
        if (n > io_scratch.cap) {
            buf = io_scratch.ensure(mrb, n);
            n = contract.labelle_component_batch_get(names.ptr, names.len, buf, io_scratch.cap);
            if (n == 0 or n > io_scratch.cap) return c.Value.int(0); // belt
        }
        if (n < 4) return c.Value.int(0);
        const count = std.mem.readInt(u32, buf[0..4], .little);
        const nfloats = (n - 4) / 4;
        var i: usize = 0;
        while (i < nfloats) : (i += 1) {
            const bits = std.mem.readInt(u32, buf[4 + i * 4 ..][0..4], .little);
            c.mrb_ary_set(mrb, arr, @intCast(i), c.Value.float(@as(f32, @bitCast(bits))));
        }
        _ = c.mrb_ary_resize(mrb, arr, @intCast(nfloats));
        return c.Value.int(@intCast(count));
    }
}

/// `raw_batch_set(names_json, array, count)` — ONE contract call writes the
/// whole swarm back. Packs every element of `array` (`count*stride` floats —
/// the array is exactly what batch_get filled and trimmed) into the io
/// scratch as raw f32, then hands the pure stream (no header) to the host,
/// which re-queries the same entities and applies them positionally.
/// Returns 0 on success. `count` is the caller's entity count (API
/// symmetry); the array length is the authoritative float count and is what
/// we pack. Host refusals RAISE — both mean the write would corrupt data,
/// and both must be loud:
///   -2  int-typed field in a named component → ArgumentError;
///   -1  the entity set changed between batch_get and batch_set (the
///       exact-size positional-coupling guard; also malformed names / host
///       not bound) → RuntimeError. The floats were computed against a
///       STALE entity set — re-run batch_get and recompute.
fn rawBatchSet(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    // Same comptime if/else gate as rawBatchGet — see the note there.
    if (comptime !contract.host_has_bulk_access) {
        raiseError(mrb, "RuntimeError", "labelle: batch_set — the host engine lacks " ++
            "batch support (script contract v1.3 needs labelle-engine >= 2.6.0); " ++
            "use per-entity get/set on this engine");
    } else {
        var np: [*]const u8 = undefined;
        var nl: c.Int = undefined;
        var arr: c.Value = undefined;
        var count: c.Int = undefined;
        // `count` (entity count) is accepted for API symmetry; the array
        // length is the authoritative float count and is what we pack below.
        _ = c.mrb_get_args(mrb, "sAi", &np, &nl, &arr, &count);
        const names = np[0..@intCast(nl)];
        const nfloats: usize = @intCast(c.labelle_mrb_ary_len(arr));
        const bytes = nfloats * 4;
        const buf = io_scratch.ensure(mrb, @max(bytes, 1));
        var i: usize = 0;
        while (i < nfloats) : (i += 1) {
            const v = c.mrb_ary_entry(arr, @intCast(i));
            const f: f32 = @floatCast(c.mrb_ensure_float_type(mrb, v).value.f);
            std.mem.writeInt(u32, buf[i * 4 ..][0..4], @bitCast(f), .little);
        }
        const rc = contract.labelle_component_batch_set(names.ptr, names.len, buf, bytes);
        if (rc == -2) raiseBatchIntRefused(mrb, names);
        if (rc != 0) raiseFmt(
            mrb,
            "RuntimeError",
            "labelle: batch_set refused for {s}: the entity set changed between " ++
                "batch_get and batch_set (spawn/destroy between the paired calls " ++
                "— the buffer was computed against a stale set; re-run batch_get " ++
                "and recompute), or the names were malformed / the host not bound",
            .{names},
        );
        return c.Value.int(0);
    }
}

// ── events ───────────────────────────────────────────────────────────────

fn rawEventEmit(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    var np: [*]const u8 = undefined;
    var nl: c.Int = undefined;
    var jp: [*]const u8 = undefined;
    var jl: c.Int = undefined;
    _ = c.mrb_get_args(mrb, "ss", &np, &nl, &jp, &jl);
    return c.Value.int(contract.labelle_event_emit(np, @intCast(nl), jp, @intCast(jl)));
}

fn rawEventSubscribe(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const name = getStr(mrb);
    contract.labelle_event_subscribe(name.ptr, name.len);
    return c.Value.nil();
}

/// `raw_event_poll` → `[name_string, payload]` or nil when the inbox is
/// empty. A truncated poll CONSUMES the entry, so never risk one: probe
/// first (NULL/cap-0 returns the NEXT entry's size, no consume), grow the
/// scratch if needed, then do the real read (the lua shim's scheme). The
/// payload arrives already decoded to symbol-keyed values — the prelude's
/// dispatch hands it straight to handlers.
fn rawEventPoll(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const next_len = contract.labelle_event_poll(null, 0);
    if (next_len == 0) return c.Value.nil();
    const buf = io_scratch.ensure(mrb, next_len);
    const n = contract.labelle_event_poll(buf, io_scratch.cap);
    const entry = buf[0..@min(n, io_scratch.cap)];

    // "<name> <json>" — name is the token before the first space.
    const space = std.mem.indexOfScalar(u8, entry, ' ') orelse entry.len;
    const name = entry[0..space];
    const payload_text = std.mem.trim(u8, entry[@min(space + 1, entry.len)..], " ");

    const pair = c.mrb_ary_new_capa(mrb, 2);
    c.mrb_ary_push(mrb, pair, c.mrb_str_new(mrb, name.ptr, @intCast(name.len)));
    if (payload_text.len == 0) {
        // Empty payload = "all defaults": hand handlers an empty Hash,
        // the same shape a "{}" payload decodes to.
        c.mrb_ary_push(mrb, pair, c.mrb_hash_new_capa(mrb, 0));
    } else {
        var p = Parser{ .mrb = mrb, .text = payload_text };
        c.mrb_ary_push(mrb, pair, p.parseDocument());
    }
    return pair;
}

// ── scene / log / time ───────────────────────────────────────────────────

fn rawSceneChange(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const name = getStr(mrb);
    return c.Value.int(contract.labelle_scene_change(name.ptr, name.len));
}

fn rawLog(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const msg = getStr(mrb);
    contract.labelle_log(msg.ptr, msg.len);
    return c.Value.nil();
}

fn rawTimeDt(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = mrb;
    _ = self;
    return c.Value.float(contract.labelle_time_dt());
}

// ── u64 helper + json entry points ───────────────────────────────────────

/// `raw_u64str(id)` — the id's UNSIGNED decimal rendering. Ids live in
/// ruby as the signed 64-bit bitcast, so `"#{id}"` on a bit-63 id prints
/// a negative number; embedding ids in payloads goes through this (the
/// prelude wraps it as Labelle.u64str).
fn rawU64Str(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    var i: c.Int = undefined;
    _ = c.mrb_get_args(mrb, "i", &i);
    var buf: [20]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("{d}", .{@as(u64, @bitCast(i))}) catch unreachable;
    const s = w.buffered();
    return c.mrb_str_new(mrb, s.ptr, @intCast(s.len));
}

fn jsonEncodeShim(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    var v: c.Value = undefined;
    _ = c.mrb_get_args(mrb, "o", &v);
    var out = Out{ .mrb = mrb };
    encodeValue(mrb, v, &out, 0);
    const json = out.slice();
    return c.mrb_str_new(mrb, json.ptr, @intCast(json.len));
}

fn jsonDecodeShim(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    const text = getStr(mrb);
    var p = Parser{ .mrb = mrb, .text = text };
    return p.parseDocument();
}

// ── gc diagnostics (test seams) ──────────────────────────────────────────

fn rawGcArena(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    return c.Value.int(c.labelle_mrb_gc_arena_save(mrb));
}

fn rawGcLive(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    return c.Value.int(@intCast(c.labelle_mrb_gc_live(mrb)));
}

fn rawGcDisable(mrb: ?*c.State, self: c.Value) callconv(.c) c.Value {
    _ = self;
    var b: c.Bool = undefined;
    _ = c.mrb_get_args(mrb, "b", &b);
    c.labelle_mrb_gc_set_disabled(mrb, b);
    return c.Value.nil();
}

// ── JSON encode (mrb_value → bytes) ──────────────────────────────────────

/// Encode output builder over the grow-only text scratch.
const Out = struct {
    mrb: ?*c.State,
    len: usize = 0,

    fn room(self: *Out, extra: usize) [*]u8 {
        const buf = text_scratch.ensure(self.mrb, self.len + extra);
        return buf + self.len;
    }

    fn byte(self: *Out, b: u8) void {
        self.room(1)[0] = b;
        self.len += 1;
    }

    fn bytes(self: *Out, s: []const u8) void {
        @memcpy(self.room(s.len)[0..s.len], s);
        self.len += s.len;
    }

    fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        // Numbers only — 40 bytes covers every i64/f64 rendering.
        var tmp: [40]u8 = undefined;
        var w = std.Io.Writer.fixed(&tmp);
        w.print(fmt, args) catch unreachable;
        self.bytes(w.buffered());
    }

    fn jsonString(self: *Out, s: []const u8) void {
        self.byte('"');
        for (s) |ch| {
            switch (ch) {
                '"' => self.bytes("\\\""),
                '\\' => self.bytes("\\\\"),
                '\n' => self.bytes("\\n"),
                '\r' => self.bytes("\\r"),
                '\t' => self.bytes("\\t"),
                0x08 => self.bytes("\\b"),
                0x0C => self.bytes("\\f"),
                0...0x07, 0x0B, 0x0E...0x1F => self.print("\\u{x:0>4}", .{ch}),
                else => self.byte(ch),
            }
        }
        self.byte('"');
    }

    fn slice(self: *Out) []const u8 {
        return text_scratch.ptr.?[0..self.len];
    }
};

const MAX_ENCODE_DEPTH = 32;

/// Encode one mrb_value as JSON. Objects (Hashes) encode with SORTED
/// string keys — pairs() order nondeterminism was lua's reason and hash
/// insertion order is ruby's: a stable encoding lets hosts and tests
/// compare payloads byte-for-byte. Integers stay SIGNED %d on purpose
/// (they may be legitimate negative component values); only values KNOWN
/// to be ids get the unsigned rendering, via Labelle.u64str. Symbols
/// encode as strings (kwargs payload convenience).
fn encodeValue(mrb: ?*c.State, v: c.Value, out: *Out, depth: usize) void {
    if (depth > MAX_ENCODE_DEPTH)
        raiseError(mrb, "ArgumentError", "labelle: json_encode nesting too deep");
    switch (v.tt) {
        .false => out.bytes(if (v.value.i == 0) "null" else "false"),
        .true => out.bytes("true"),
        .integer => out.print("{d}", .{v.value.i}),
        .float => {
            const f = v.value.f;
            if (std.math.isNan(f) or std.math.isInf(f))
                raiseError(mrb, "ArgumentError", "labelle: json_encode: non-finite number");
            out.print("{d}", .{f});
        },
        .string => out.jsonString(vm_mod.strSlice(v)),
        .symbol => {
            var nl: c.Int = 0;
            const np = c.mrb_sym_name_len(mrb, v.value.sym, &nl) orelse
                raiseError(mrb, "TypeError", "labelle: json_encode: unnameable symbol");
            out.jsonString(np[0..@intCast(nl)]);
        },
        .array => {
            out.byte('[');
            const len = c.labelle_mrb_ary_len(v);
            var i: c.Int = 0;
            while (i < len) : (i += 1) {
                if (i > 0) out.byte(',');
                encodeValue(mrb, c.mrb_ary_entry(v, i), out, depth + 1);
            }
            out.byte(']');
        },
        .hash => {
            const keys = c.mrb_hash_keys(mrb, v);
            const nkeys: usize = @intCast(c.labelle_mrb_ary_len(keys));
            if (nkeys > MAX_OBJECT_KEYS)
                raiseError(mrb, "ArgumentError", "labelle: json_encode: too many object keys");
            // Materialize key names — string keys borrow their (stable)
            // RString bytes, symbol keys are COPIED (see copySymName) —
            // sort, then emit.
            var name_storage: [2048]u8 = undefined;
            var names: [MAX_OBJECT_KEYS][]const u8 = undefined;
            var vals: [MAX_OBJECT_KEYS]c.Value = undefined;
            var used: usize = 0;
            for (0..nkeys) |i| {
                const k = c.mrb_ary_entry(keys, @intCast(i));
                names[i] = switch (k.tt) {
                    .string => vm_mod.strSlice(k),
                    .symbol => copySymName(mrb, k.value.sym, &name_storage, &used),
                    else => raiseError(mrb, "TypeError", "labelle: json_encode: object keys must be strings or symbols"),
                };
                vals[i] = k;
            }
            var i: usize = 1;
            while (i < nkeys) : (i += 1) {
                const ni = names[i];
                const vi = vals[i];
                var j = i;
                while (j > 0 and std.mem.order(u8, names[j - 1], ni) == .gt) : (j -= 1) {
                    names[j] = names[j - 1];
                    vals[j] = vals[j - 1];
                }
                names[j] = ni;
                vals[j] = vi;
            }
            out.byte('{');
            for (0..nkeys) |k_i| {
                if (k_i > 0) out.byte(',');
                out.jsonString(names[k_i]);
                out.byte(':');
                encodeValue(mrb, c.mrb_hash_get(mrb, v, vals[k_i]), out, depth + 1);
            }
            out.byte('}');
        },
        else => raiseError(mrb, "TypeError", "labelle: json_encode: unsupported value type"),
    }
}

// ── JSON decode (bytes → mrb_value) ──────────────────────────────────────

/// Recursive-descent JSON reader producing mruby values: objects become
/// SYMBOL-keyed Hashes (the event-payload shape the RFC pins), arrays
/// become Arrays, and INTEGER-LOOKING tokens (all digits, optional '-')
/// build with WRAPPING u64 arithmetic + i64 bitcast — a token ≥ 2^63 (a
/// bit-63 entity id in a payload) lands exactly on the signed bitcast the
/// raw shims use for ids. Ruby-side arithmetic could never do this: mruby
/// raises RangeError on integer overflow. True float tokens (fractions,
/// exponents) parse as f64. Malformed input raises RuntimeError.
const Parser = struct {
    mrb: ?*c.State,
    text: []const u8,
    pos: usize = 0,

    fn parseDocument(p: *Parser) c.Value {
        const v = p.parseValue();
        p.skipWs();
        if (p.pos < p.text.len)
            raiseError(p.mrb, "RuntimeError", "labelle: json_decode: trailing garbage");
        return v;
    }

    fn peek(p: *Parser) u8 {
        return if (p.pos < p.text.len) p.text[p.pos] else 0;
    }

    fn next(p: *Parser) u8 {
        const b = p.peek();
        p.pos += 1;
        return b;
    }

    fn skipWs(p: *Parser) void {
        while (p.pos < p.text.len) : (p.pos += 1) {
            switch (p.text[p.pos]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn expect(p: *Parser, b: u8) void {
        if (p.next() != b)
            raiseError(p.mrb, "RuntimeError", "labelle: json_decode: malformed document");
    }

    /// An object key: '"' string '"' ':' — returns the UNESCAPED bytes
    /// (borrowed from the text scratch until the next unescape).
    fn parseKey(p: *Parser) []const u8 {
        p.skipWs();
        if (p.peek() != '"')
            raiseError(p.mrb, "RuntimeError", "labelle: json_decode: expected object key");
        const key = p.parseStringBytes();
        p.skipWs();
        p.expect(':');
        return key;
    }

    fn parseValue(p: *Parser) c.Value {
        p.skipWs();
        const ch = p.peek();
        switch (ch) {
            '{' => {
                p.pos += 1;
                const hash = c.mrb_hash_new_capa(p.mrb, 4);
                p.skipWs();
                if (p.peek() == '}') {
                    p.pos += 1;
                    return hash;
                }
                while (true) {
                    const key = p.parseKey();
                    const key_sym = c.mrb_intern(p.mrb, key.ptr, key.len);
                    const v = p.parseValue();
                    c.mrb_hash_set(p.mrb, hash, c.Value.symbol(key_sym), v);
                    p.skipWs();
                    switch (p.next()) {
                        ',' => {},
                        '}' => return hash,
                        else => raiseError(p.mrb, "RuntimeError", "labelle: json_decode: expected ',' or '}'"),
                    }
                }
            },
            '[' => {
                p.pos += 1;
                const ary = c.mrb_ary_new_capa(p.mrb, 4);
                p.skipWs();
                if (p.peek() == ']') {
                    p.pos += 1;
                    return ary;
                }
                while (true) {
                    const v = p.parseValue();
                    c.mrb_ary_push(p.mrb, ary, v);
                    p.skipWs();
                    switch (p.next()) {
                        ',' => {},
                        ']' => return ary,
                        else => raiseError(p.mrb, "RuntimeError", "labelle: json_decode: expected ',' or ']'"),
                    }
                }
            },
            '"' => {
                const s = p.parseStringBytes();
                return c.mrb_str_new(p.mrb, s.ptr, @intCast(s.len));
            },
            't' => {
                p.expectWord("true");
                return c.Value.boolean(true);
            },
            'f' => {
                p.expectWord("false");
                return c.Value.boolean(false);
            },
            'n' => {
                p.expectWord("null");
                return c.Value.nil();
            },
            else => return p.parseNumber(),
        }
    }

    fn expectWord(p: *Parser, comptime w: []const u8) void {
        if (p.pos + w.len > p.text.len or !std.mem.eql(u8, p.text[p.pos..][0..w.len], w))
            raiseError(p.mrb, "RuntimeError", "labelle: json_decode: malformed literal");
        p.pos += w.len;
    }

    /// String contents, unescaped into the text scratch (valid until the
    /// next unescape/encode). `pos` sits on the opening quote.
    fn parseStringBytes(p: *Parser) []const u8 {
        p.pos += 1; // opening quote
        // Unescaping only shrinks, so the raw span bounds the output.
        const start = p.pos;
        var end = start;
        var has_escape = false;
        while (end < p.text.len and p.text[end] != '"') : (end += 1) {
            if (p.text[end] == '\\') {
                has_escape = true;
                end += 1; // skip the escaped byte ('\uXXXX' rescans below)
            }
        }
        if (end >= p.text.len)
            raiseError(p.mrb, "RuntimeError", "labelle: json_decode: unterminated string");
        if (!has_escape) {
            p.pos = end + 1;
            return p.text[start..end];
        }
        const raw = p.text[start..end];
        const buf = text_scratch.ensure(p.mrb, raw.len);
        var out_len: usize = 0;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '\\') {
                buf[out_len] = raw[i];
                out_len += 1;
                i += 1;
                continue;
            }
            i += 1;
            if (i >= raw.len)
                raiseError(p.mrb, "RuntimeError", "labelle: json_decode: bad escape");
            const e = raw[i];
            i += 1;
            switch (e) {
                '"', '\\', '/' => {
                    buf[out_len] = e;
                    out_len += 1;
                },
                'n' => {
                    buf[out_len] = '\n';
                    out_len += 1;
                },
                't' => {
                    buf[out_len] = '\t';
                    out_len += 1;
                },
                'r' => {
                    buf[out_len] = '\r';
                    out_len += 1;
                },
                'b' => {
                    buf[out_len] = 0x08;
                    out_len += 1;
                },
                'f' => {
                    buf[out_len] = 0x0C;
                    out_len += 1;
                },
                'u' => {
                    // BMP-only, the lua codec's documented limit.
                    if (i + 4 > raw.len)
                        raiseError(p.mrb, "RuntimeError", "labelle: json_decode: bad \\u escape");
                    const cp = std.fmt.parseInt(u16, raw[i..][0..4], 16) catch
                        raiseError(p.mrb, "RuntimeError", "labelle: json_decode: bad \\u escape");
                    i += 4;
                    out_len += std.unicode.utf8Encode(cp, buf[out_len..][0..4]) catch
                        raiseError(p.mrb, "RuntimeError", "labelle: json_decode: bad \\u escape");
                },
                else => raiseError(p.mrb, "RuntimeError", "labelle: json_decode: bad escape"),
            }
        }
        p.pos = end + 1;
        return buf[0..out_len];
    }

    fn parseNumber(p: *Parser) c.Value {
        const start = p.pos;
        while (p.pos < p.text.len) : (p.pos += 1) {
            switch (p.text[p.pos]) {
                '-', '+', '.', 'e', 'E', '0'...'9' => {},
                else => break,
            }
        }
        const tok = p.text[start..p.pos];
        if (tok.len == 0)
            raiseError(p.mrb, "RuntimeError", "labelle: json_decode: bad number");
        // Integer-looking tokens wrap mod 2^64 (see the Parser doc).
        const digits = if (tok[0] == '-') tok[1..] else tok;
        var all_digits = digits.len > 0;
        for (digits) |d| {
            if (d < '0' or d > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            var acc: u64 = 0;
            for (digits) |d| acc = acc *% 10 +% (d - '0');
            if (tok[0] == '-') acc = 0 -% acc;
            return c.Value.int(@bitCast(acc));
        }
        const f = std.fmt.parseFloat(f64, tok) catch
            raiseError(p.mrb, "RuntimeError", "labelle: json_decode: bad number");
        return c.Value.float(f);
    }

    /// Skip one complete value WITHOUT materializing ruby objects — how
    /// get_into passes over JSON keys that match no declared field.
    fn skipValue(p: *Parser) void {
        p.skipWs();
        switch (p.peek()) {
            '{', '[' => {
                var depth: usize = 0;
                while (p.pos < p.text.len) {
                    switch (p.text[p.pos]) {
                        '{', '[' => depth += 1,
                        '}', ']' => {
                            depth -= 1;
                            if (depth == 0) {
                                p.pos += 1;
                                return;
                            }
                        },
                        '"' => {
                            _ = p.parseStringBytes();
                            continue;
                        },
                        else => {},
                    }
                    p.pos += 1;
                }
                raiseError(p.mrb, "RuntimeError", "labelle: json_decode: unterminated container");
            },
            '"' => _ = p.parseStringBytes(),
            else => _ = p.parseValue(),
        }
    }
};
