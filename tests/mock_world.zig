//! Mock host world — the test-side implementation of the Script Runtime
//! Contract (labelle_script.h v1).
//!
//! In production the assembler-generated game binary exports the
//! `labelle_*` symbols and the plugin's externs resolve against them at
//! link time. Tests reproduce that model exactly: this file `export`s the
//! same symbols into the test binary, backed by a toy world (a rework of
//! the engine's poc/language-plugins spike host, extended to the full v1
//! surface: rc conventions, remove, query, prefab, scene, dt stamping).
//! What the tests assert is therefore the REAL seam — same symbols, same
//! ABI, same JSON-in/JSON-out conventions — with a host small enough to
//! inspect from Zig.
//!
//! POC-style shortcuts (fine for a mock, wrong for an engine): fixed-size
//! arrays, JSON stored as opaque strings (only `query` inspects names),
//! single script inbox, main-thread only. Because payloads stay opaque,
//! the real host's PARSE-side validation is deliberately not mirrored:
//! component_set/event_emit here accept bytes the engine refuses with -1
//! (malformed JSON, trailing garbage after the document, non-empty
//! payloads on void events). The Lua plugin only ever sends json.encode
//! output or "", so no test depends on that leniency; the engine's own
//! script_contract tests pin the strict behavior.

const std = @import("std");

const NAME_CAP = 48;
// Big enough that a component (and event payload) can exceed the Lua
// shim's 4 KiB initial scratch — the grow-only scratch tests need the
// mock to store and serve >4096-byte JSON intact.
const JSON_CAP = 8192;
const EVENT_CAP = NAME_CAP + JSON_CAP;
const LOG_CAP = 2048; // must hold a full Lua traceback line
// Big enough that a query over 20-digit ids can outgrow the Lua shim's
// fixed QUERY_BUF_CAP (8 KiB ÷ 21 bytes/id ≈ 390) — the grow-and-retry
// test needs the mock to actually overflow it — and that the per-frame
// allocation hot loops can hold their ~1k live entities (+ a verdict
// entity) at once.
const MAX_ENTITIES = 1200;
const MAX_COMPONENTS = 8;
const MAX_EVENTS = 64;
const MAX_SUBS = 16;
const MAX_LOGS = 64;

const Component = struct {
    name: [NAME_CAP]u8 = undefined,
    name_len: usize = 0,
    json: [JSON_CAP]u8 = undefined,
    json_len: usize = 0,

    fn nameSlice(self: *const Component) []const u8 {
        return self.name[0..self.name_len];
    }
    fn jsonSlice(self: *const Component) []const u8 {
        return self.json[0..self.json_len];
    }
};

const Entity = struct {
    id: u64 = 0,
    alive: bool = false,
    comps: [MAX_COMPONENTS]Component = undefined,
    comp_count: usize = 0,
};

const Text = struct {
    buf: [EVENT_CAP]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }
};

const LogLine = struct {
    buf: [LOG_CAP]u8 = undefined,
    len: usize = 0,
};

const World = struct {
    next_id: u64 = 1,
    entities: [MAX_ENTITIES]Entity = undefined,
    entity_count: usize = 0,

    /// Script → host emissions (labelle_event_emit), in order.
    events: [MAX_EVENTS]Text = undefined,
    event_count: usize = 0,

    /// Receive side: subscriptions + the FIFO inbox drained via poll.
    subs: [MAX_SUBS]Text = undefined,
    sub_count: usize = 0,
    inbox: [MAX_EVENTS]Text = undefined,
    inbox_head: usize = 0,
    inbox_count: usize = 0,

    logs: [MAX_LOGS]LogLine = undefined,
    log_count: usize = 0,

    scene: [NAME_CAP]u8 = undefined,
    scene_len: usize = 0,

    /// What labelle_time_dt reports; 0 until the plugin's first stamp —
    /// mirroring the contract's "0 before the first tick".
    dt: f32 = 0,

    fn find(self: *World, id: u64) ?*Entity {
        for (self.entities[0..self.entity_count]) |*e| {
            if (e.alive and e.id == id) return e;
        }
        return null;
    }
};

/// Deliberately `undefined` so the multi-megabyte component store lands
/// in .bss instead of being embedded in the test binary as .data; every
/// test calls `reset()` (via the shared `fresh()`) before touching the
/// mock, which is what makes the state defined.
pub var world: World = undefined;

/// Fresh world between tests — global state demands explicit resets.
/// Zero everything, then restore the one non-zero default (ids start
/// at 1 — 0 is the contract's failure sentinel).
pub fn reset() void {
    @memset(std.mem.asBytes(&world), 0);
    world.next_id = 1;
}

// ── contract exports: version ────────────────────────────────────────────

export fn labelle_contract_version() u32 {
    return 1;
}

// ── contract exports: entities ───────────────────────────────────────────

export fn labelle_entity_create() u64 {
    if (world.entity_count >= MAX_ENTITIES) return 0;
    const e = &world.entities[world.entity_count];
    e.* = .{ .id = world.next_id, .alive = true };
    world.next_id += 1;
    world.entity_count += 1;
    return e.id;
}

export fn labelle_entity_destroy(id: u64) void {
    if (world.find(id)) |e| e.alive = false;
}

export fn labelle_prefab_spawn(
    name: [*]const u8,
    name_len: usize,
    params_json: ?[*]const u8,
    params_len: usize,
) u64 {
    const id = labelle_entity_create();
    if (id == 0) return 0;
    // Record the prefab identity as a component so tests can assert on it,
    // and honor the {"x":…,"y":…} params as the spawn Position.
    var buf: [JSON_CAP]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("{{\"name\":\"{s}\"}}", .{name[0..name_len]}) catch return 0;
    setComponent(id, "Prefab", w.buffered());
    if (params_json != null and params_len > 0) {
        setComponent(id, "Position", params_json.?[0..params_len]);
    } else {
        setComponent(id, "Position", "{\"x\":0,\"y\":0}");
    }
    return id;
}

// ── contract exports: components ─────────────────────────────────────────

/// Shared store path (also used by prefab_spawn). Update-in-place when the
/// component exists — the common per-tick path.
fn setComponent(id: u64, name: []const u8, json: []const u8) void {
    const e = world.find(id) orelse return;
    const n = name[0..@min(name.len, NAME_CAP)];
    const j = json[0..@min(json.len, JSON_CAP)];
    for (e.comps[0..e.comp_count]) |*comp| {
        if (std.mem.eql(u8, comp.nameSlice(), n)) {
            @memcpy(comp.json[0..j.len], j);
            comp.json_len = j.len;
            return;
        }
    }
    if (e.comp_count >= MAX_COMPONENTS) return;
    const comp = &e.comps[e.comp_count];
    @memcpy(comp.name[0..n.len], n);
    comp.name_len = n.len;
    @memcpy(comp.json[0..j.len], j);
    comp.json_len = j.len;
    e.comp_count += 1;
}

fn entityHas(e: *const Entity, name: []const u8) bool {
    for (e.comps[0..e.comp_count]) |*comp| {
        if (std.mem.eql(u8, comp.nameSlice(), name)) return true;
    }
    return false;
}

export fn labelle_component_set(
    id: u64,
    name: [*]const u8,
    name_len: usize,
    json: [*]const u8,
    json_len: usize,
) i32 {
    if (world.find(id) == null) return -1; // unknown-or-dead entity
    setComponent(id, name[0..name_len], json[0..json_len]);
    return 0;
}

export fn labelle_component_get(
    id: u64,
    name: [*]const u8,
    name_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    const e = world.find(id) orelse return 0;
    const n = name[0..@min(name_len, NAME_CAP)];
    for (e.comps[0..e.comp_count]) |*comp| {
        if (std.mem.eql(u8, comp.nameSlice(), n)) {
            // Contract v1 required-size sizing: RETURN the bytes the
            // complete JSON needs; WRITE all-or-nothing (only when it
            // fits — a truncated JSON object prefix is useless).
            // NULL/cap-0 out is the pure sizing probe.
            const required = comp.json_len;
            if (out) |buf| {
                if (required <= out_cap) @memcpy(buf[0..required], comp.jsonSlice());
            }
            return required;
        }
    }
    return 0;
}

export fn labelle_component_has(id: u64, name: [*]const u8, name_len: usize) i32 {
    const e = world.find(id) orelse return 0;
    return if (entityHas(e, name[0..name_len])) 1 else 0;
}

export fn labelle_component_remove(id: u64, name: [*]const u8, name_len: usize) i32 {
    const e = world.find(id) orelse return -1;
    const n = name[0..name_len];
    for (e.comps[0..e.comp_count], 0..) |*comp, i| {
        if (std.mem.eql(u8, comp.nameSlice(), n)) {
            // Swap-remove: component order is not part of the contract.
            e.comps[i] = e.comps[e.comp_count - 1];
            e.comp_count -= 1;
            return 0;
        }
    }
    return 0; // absent-but-known removes are ok (idempotent)
}

// ── contract exports: bulk component access (contract v1.3, #41) ─────────
//
// The packed per-component codec and the batched whole-query f32 stream.
// The engine host reflects its COMPTIME component registry for field
// types; the mock declares the same knowledge as data (the schema table
// below). A component NOT in the table plays the "non-packable" role —
// 0xFF sentinel on get, -1 refusal on set, zero stream floats in a batch
// — exactly like an engine component with non-scalar fields, which is
// what keeps every JSON-fallback path testable against this mock.

const PackedKind = enum { f32, i64, boolean, u64 };
const PackedField = struct { name: []const u8, kind: PackedKind };
const PackedType = struct { name: []const u8, fields: []const PackedField };

const packed_types = [_]PackedType{
    // One field of each packed scalar kind — the packed round-trip
    // component, and (through its int fields) the batch-refusal one.
    .{ .name = "Stats", .fields = &.{
        .{ .name = "power", .kind = .f32 },
        .{ .name = "score", .kind = .i64 },
        .{ .name = "alive", .kind = .boolean },
        .{ .name = "seed", .kind = .u64 },
    } },
    // Float-only pair — the batch round-trip components.
    .{ .name = "BatchPos", .fields = &.{
        .{ .name = "x", .kind = .f32 },
        .{ .name = "y", .kind = .f32 },
    } },
    .{ .name = "BatchVel", .fields = &.{
        .{ .name = "vx", .kind = .f32 },
        .{ .name = "vy", .kind = .f32 },
    } },
};

fn packedTypeOf(name: []const u8) ?*const PackedType {
    for (&packed_types) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn typeHasIntField(t: *const PackedType) bool {
    for (t.fields) |f| {
        if (f.kind == .i64 or f.kind == .u64) return true;
    }
    return false;
}

fn payloadSize(kind: PackedKind) usize {
    return switch (kind) {
        .f32 => 4,
        .i64, .u64 => 8,
        .boolean => 1,
    };
}

/// A scalar pulled out of a stored flat-JSON component (typed by token
/// shape: the store is text, so int vs float is decided by the token).
const ScalarVal = union(enum) { f: f64, i: i64, u: u64, b: bool };

/// Scan a FLAT JSON object (the only shape the packable schemas store)
/// for `"name":` and return the raw value token.
fn jsonFieldToken(json: []const u8, name: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, json, search, name)) |at| {
        search = at + 1;
        // Must be a quoted key followed by ':'.
        if (at < 1 or json[at - 1] != '"') continue;
        var p = at + name.len;
        if (p >= json.len or json[p] != '"') continue;
        p += 1;
        while (p < json.len and (json[p] == ' ' or json[p] == '\t')) p += 1;
        if (p >= json.len or json[p] != ':') continue;
        p += 1;
        while (p < json.len and (json[p] == ' ' or json[p] == '\t')) p += 1;
        const start = p;
        while (p < json.len and json[p] != ',' and json[p] != '}') p += 1;
        return std.mem.trim(u8, json[start..p], " \t");
    }
    return null;
}

fn jsonScalar(json: []const u8, name: []const u8) ?ScalarVal {
    const tok = jsonFieldToken(json, name) orelse return null;
    if (tok.len == 0) return null;
    if (std.mem.eql(u8, tok, "true")) return .{ .b = true };
    if (std.mem.eql(u8, tok, "false")) return .{ .b = false };
    const fractional = std.mem.indexOfAny(u8, tok, ".eE") != null;
    if (!fractional) {
        if (tok[0] == '-') {
            if (std.fmt.parseInt(i64, tok, 10) catch null) |v| return .{ .i = v };
        } else {
            if (std.fmt.parseInt(u64, tok, 10) catch null) |v| return .{ .u = v };
        }
    }
    if (std.fmt.parseFloat(f64, tok) catch null) |v| return .{ .f = v };
    return null;
}

fn scalarToF32(v: ScalarVal) f32 {
    return switch (v) {
        .f => |x| @floatCast(x),
        .i => |x| @floatFromInt(x),
        .u => |x| @floatFromInt(x),
        .b => |x| if (x) 1 else 0,
    };
}

fn scalarToI64(v: ScalarVal) i64 {
    return switch (v) {
        // Saturating, never trapping: this is the GET/stream side reading
        // HOST-owned stored text (whatever the JSON leniency let in).
        .f => |x| if (!std.math.isFinite(x))
            0
        else if (x >= 9223372036854775808.0)
            std.math.maxInt(i64)
        else if (x < -9223372036854775808.0)
            std.math.minInt(i64)
        else
            @intFromFloat(x),
        .i => |x| x,
        // The documented 64-bit two's-complement pair (see coerceForKind).
        .u => |x| @bitCast(x),
        .b => |x| @intFromBool(x),
    };
}

fn scalarToU64(v: ScalarVal) u64 {
    return switch (v) {
        .f => |x| if (!std.math.isFinite(x) or x < 0)
            0
        else if (x >= 18446744073709551616.0)
            std.math.maxInt(u64)
        else
            @intFromFloat(x),
        // The documented 64-bit two's-complement pair (see coerceForKind).
        .i => |x| @bitCast(x),
        .u => |x| x,
        .b => |x| @intFromBool(x),
    };
}

fn scalarToBool(v: ScalarVal) bool {
    return switch (v) {
        .f => |x| x != 0,
        .i => |x| x != 0,
        .u => |x| x != 0,
        .b => |x| x,
    };
}

/// Append one schema field's JSON ("name":value) from its ScalarVal —
/// the shared serializer for set_packed and batch_set (schema order,
/// value coerced into the field's kind).
fn writeJsonField(w: *std.Io.Writer, f: PackedField, v: ScalarVal, first: bool) !void {
    if (!first) try w.writeByte(',');
    switch (f.kind) {
        .f32 => try w.print("\"{s}\":{d}", .{ f.name, scalarToF32(v) }),
        .i64 => try w.print("\"{s}\":{d}", .{ f.name, scalarToI64(v) }),
        .u64 => try w.print("\"{s}\":{d}", .{ f.name, scalarToU64(v) }),
        .boolean => try w.print("\"{s}\":{}", .{ f.name, scalarToBool(v) }),
    }
}

fn defaultScalar(kind: PackedKind) ScalarVal {
    return switch (kind) {
        .f32 => .{ .f = 0 },
        .i64 => .{ .i = 0 },
        .u64 => .{ .u = 0 },
        .boolean => .{ .b = false },
    };
}

/// The engine host's packed-SET refusal semantics, mirrored (round-1
/// panic-safety hardening): a tagged value the target field cannot
/// represent — negative into u64, u64 past maxInt(i64) into i64, a
/// non-finite or out-of-range float into either int kind — makes the
/// whole set REFUSE (-1) so the binding falls back to JSON, which
/// surfaces the value faithfully. Never clamp/zero on the SET path;
/// the clamping scalarTo* helpers above serve only the GET/stream side
/// (host-owned data).
fn coerceForKind(kind: PackedKind, v: ScalarVal) ?ScalarVal {
    switch (kind) {
        .f32 => switch (v) {
            // Engine parity (#45): a FINITE f64 (the SET-side tag 4)
            // whose f32 narrow is non-finite refuses — never smuggle an
            // inf the wire's documented non-finite rejection would stop.
            // (Bindings guard this before emitting; belt on script-
            // supplied bytes.)
            .f => |x| return if (std.math.isFinite(x) and
                !std.math.isFinite(@as(f32, @floatCast(x)))) null else v,
            else => return v,
        },
        .boolean => return v, // total: bool compares against zero
        .i64 => switch (v) {
            // Engine parity: the 64-BIT BITCAST PAIR — the other 64-bit
            // tag lands via two's-complement bitcast (lossless round trip
            // for signed-only bindings), never a range refusal.
            .u => |x| return .{ .i = @bitCast(x) },
            .f => |x| return if (!std.math.isFinite(x) or
                x < -9223372036854775808.0 or x >= 9223372036854775808.0) null else v,
            else => return v,
        },
        .u64 => switch (v) {
            .i => |x| return .{ .u = @bitCast(x) },
            .f => |x| return if (!std.math.isFinite(x) or
                x < 0 or x >= 18446744073709551616.0) null else v,
            else => return v,
        },
    }
}

export fn labelle_component_get_packed(
    id: u64,
    name: [*]const u8,
    name_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    const e = world.find(id) orelse return 0;
    const n = name[0..@min(name_len, NAME_CAP)];
    const json = blk: {
        for (e.comps[0..e.comp_count]) |*comp| {
            if (std.mem.eql(u8, comp.nameSlice(), n)) break :blk comp.jsonSlice();
        }
        return 0; // absent keeps the JSON get's 0 sentinel
    };
    const buf: []u8 = if (out) |p| p[0..out_cap] else &.{};
    const t = packedTypeOf(n) orelse {
        // Not in the schema table = the engine's "non-scalar component":
        // the single 0xFF sentinel byte → the binding falls back to JSON.
        if (buf.len >= 1) buf[0] = 0xFF;
        return 1;
    };
    // Required-size / all-or-nothing, like the JSON get.
    var required: usize = 1;
    for (t.fields) |f| required += 1 + f.name.len + 1 + payloadSize(f.kind);
    if (required > buf.len) return required;
    var w: usize = 0;
    buf[w] = @intCast(t.fields.len);
    w += 1;
    for (t.fields) |f| {
        buf[w] = @intCast(f.name.len);
        w += 1;
        @memcpy(buf[w..][0..f.name.len], f.name);
        w += f.name.len;
        const v = jsonScalar(json, f.name) orelse defaultScalar(f.kind);
        switch (f.kind) {
            .f32 => {
                buf[w] = 0;
                std.mem.writeInt(u32, buf[w + 1 ..][0..4], @bitCast(scalarToF32(v)), .little);
                w += 5;
            },
            .i64 => {
                buf[w] = 1;
                std.mem.writeInt(i64, buf[w + 1 ..][0..8], scalarToI64(v), .little);
                w += 9;
            },
            .boolean => {
                buf[w] = 2;
                buf[w + 1] = @intFromBool(scalarToBool(v));
                w += 2;
            },
            .u64 => {
                buf[w] = 3;
                std.mem.writeInt(u64, buf[w + 1 ..][0..8], scalarToU64(v), .little);
                w += 9;
            },
        }
    }
    return required;
}

export fn labelle_component_set_packed(
    id: u64,
    name: [*]const u8,
    name_len: usize,
    buf_ptr: ?[*]const u8,
    buf_len: usize,
) i32 {
    if (world.find(id) == null) return -1;
    const n = name[0..@min(name_len, NAME_CAP)];
    const t = packedTypeOf(n) orelse return -1; // non-packable → JSON fallback
    const buf = (buf_ptr orelse return -1)[0..buf_len];
    if (buf.len < 1 or buf[0] == 0xFF) return -1;
    // REPLACE semantics: defaults first, then apply matched record fields.
    var vals: [8]ScalarVal = undefined;
    for (t.fields, 0..) |f, i| vals[i] = defaultScalar(f.kind);
    const field_count = buf[0];
    var pos: usize = 1;
    var i: usize = 0;
    while (i < field_count) : (i += 1) {
        if (pos >= buf.len) return -1;
        const nlen = buf[pos];
        pos += 1;
        if (pos + nlen > buf.len) return -1;
        const fname = buf[pos..][0..nlen];
        pos += nlen;
        if (pos >= buf.len) return -1;
        const tag = buf[pos];
        pos += 1;
        var v: ScalarVal = undefined;
        switch (tag) {
            0 => {
                if (pos + 4 > buf.len) return -1;
                v = .{ .f = @as(f32, @bitCast(std.mem.readInt(u32, buf[pos..][0..4], .little))) };
                pos += 4;
            },
            1 => {
                if (pos + 8 > buf.len) return -1;
                v = .{ .i = std.mem.readInt(i64, buf[pos..][0..8], .little) };
                pos += 8;
            },
            2 => {
                if (pos + 1 > buf.len) return -1;
                v = .{ .b = buf[pos] != 0 };
                pos += 1;
            },
            3 => {
                if (pos + 8 > buf.len) return -1;
                v = .{ .u = std.mem.readInt(u64, buf[pos..][0..8], .little) };
                pos += 8;
            },
            4 => { // f64 — SET-side only (since v1.3, #45): full-precision
                // floats so float→int coercion is exact past f32's
                // 24-bit mantissa. GET stays f32-only.
                if (pos + 8 > buf.len) return -1;
                v = .{ .f = @bitCast(std.mem.readInt(u64, buf[pos..][0..8], .little)) };
                pos += 8;
            },
            else => return -1,
        }
        for (t.fields, 0..) |f, fi| {
            if (std.mem.eql(u8, f.name, fname)) {
                // Engine parity: an unrepresentable value refuses the
                // WHOLE set — the binding then falls back to JSON.
                vals[fi] = coerceForKind(f.kind, v) orelse return -1;
            }
        }
    }
    // Engine parity: bytes past the declared field records are a
    // malformed buffer — refuse, don't half-accept.
    if (pos != buf.len) return -1;
    // Serialize in schema order and store through the shared path.
    var jbuf: [JSON_CAP]u8 = undefined;
    var w = std.Io.Writer.fixed(&jbuf);
    w.writeByte('{') catch return -1;
    for (t.fields, 0..) |f, fi| {
        writeJsonField(&w, f, vals[fi], fi == 0) catch return -1;
    }
    w.writeByte('}') catch return -1;
    setComponent(id, n, w.buffered());
    return 0;
}

/// `labelle_component_batch_get`'s int-field refusal sentinel — C's
/// `(size_t)-2`, matching the header's LABELLE_BATCH_INT_REFUSED.
pub const batch_int_refused: usize = std.math.maxInt(usize) - 1;

/// Tokenize a batch/query names array (the mock's forgiving parse).
fn parseNames(input: []const u8, storage: *[8][]const u8) ?[]const []const u8 {
    if (std.mem.indexOfScalar(u8, input, '[') == null) return null;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, input, "[]\", \t");
    while (it.next()) |tok| {
        if (n >= storage.len) break;
        storage[n] = tok;
        n += 1;
    }
    if (n == 0) return null;
    return storage[0..n];
}

export fn labelle_component_batch_get(
    names_json: [*]const u8,
    names_json_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    var storage: [8][]const u8 = undefined;
    const names = parseNames(names_json[0..names_json_len], &storage) orelse return 0;
    // Int-field refusal decides before any other outcome (the engine's
    // order): i64/u64 cannot ride the f32 stream without corruption.
    for (names) |nm| {
        if (packedTypeOf(nm)) |t| {
            if (typeHasIntField(t)) return batch_int_refused;
        }
    }
    const buf: []u8 = if (out) |p| p[0..out_cap] else &.{};
    var count: u32 = 0;
    var pos: usize = 4; // the u32 count header
    outer: for (world.entities[0..world.entity_count]) |*e| {
        if (!e.alive) continue;
        for (names) |nm| {
            if (!entityHas(e, nm)) continue :outer;
        }
        count += 1;
        for (names) |nm| {
            // Schema-less components contribute zero floats (the engine's
            // skipped non-scalar fields), keeping get and set aligned.
            const t = packedTypeOf(nm) orelse continue;
            const json = blk: {
                for (e.comps[0..e.comp_count]) |*comp| {
                    if (std.mem.eql(u8, comp.nameSlice(), nm)) break :blk comp.jsonSlice();
                }
                unreachable; // entityHas guaranteed presence
            };
            for (t.fields) |f| {
                const v = jsonScalar(json, f.name) orelse defaultScalar(f.kind);
                if (pos + 4 <= buf.len) {
                    std.mem.writeInt(u32, buf[pos..][0..4], @bitCast(scalarToF32(v)), .little);
                }
                pos += 4; // advance past the cap: required-size return
            }
        }
    }
    if (buf.len >= 4) std.mem.writeInt(u32, buf[0..4], count, .little);
    return pos;
}

export fn labelle_component_batch_set(
    names_json: [*]const u8,
    names_json_len: usize,
    buf_ptr: ?[*]const u8,
    buf_len: usize,
) i32 {
    var storage: [8][]const u8 = undefined;
    const names = parseNames(names_json[0..names_json_len], &storage) orelse return -1;
    for (names) |nm| {
        if (packedTypeOf(nm)) |t| {
            if (typeHasIntField(t)) return -2; // the get sentinel's i32 twin
        }
    }
    const buf = if (buf_ptr) |p| p[0..buf_len] else &[_]u8{};
    // PREFLIGHT (engine parity): size the re-queried set FIRST and refuse
    // BEFORE any write on mismatch — a refused batch_set performs no
    // writes, so the documented "re-get and recompute" retry can never
    // double-apply a prefix.
    var expected: usize = 0;
    outer_pre: for (world.entities[0..world.entity_count]) |*e| {
        if (!e.alive) continue;
        for (names) |nm| {
            if (!entityHas(e, nm)) continue :outer_pre;
        }
        for (names) |nm| {
            const t = packedTypeOf(nm) orelse continue;
            expected += t.fields.len * 4;
        }
    }
    if (expected != buf.len) return -1;
    var pos: usize = 0; // pure f32 stream, no header
    outer: for (world.entities[0..world.entity_count]) |*e| {
        if (!e.alive) continue;
        for (names) |nm| {
            if (!entityHas(e, nm)) continue :outer;
        }
        for (names) |nm| {
            const t = packedTypeOf(nm) orelse continue;
            // Batch-eligible schemas are float/bool only (ints refused
            // above), so each field consumes exactly one f32.
            var jbuf: [JSON_CAP]u8 = undefined;
            var w = std.Io.Writer.fixed(&jbuf);
            w.writeByte('{') catch return -1;
            for (t.fields, 0..) |f, fi| {
                if (pos + 4 > buf.len) return -1; // belt: preflight sized this
                const fv: f32 = @bitCast(std.mem.readInt(u32, buf[pos..][0..4], .little));
                pos += 4;
                const v: ScalarVal = switch (f.kind) {
                    .boolean => .{ .b = fv != 0 },
                    else => .{ .f = fv },
                };
                writeJsonField(&w, f, v, fi == 0) catch return -1;
            }
            w.writeByte('}') catch return -1;
            setComponent(e.id, nm, w.buffered());
        }
    }
    // Belt on top of the preflight.
    if (pos != buf.len) return -1;
    return 0;
}

// ── contract exports: queries ────────────────────────────────────────────

export fn labelle_query(
    names_json: [*]const u8,
    names_json_len: usize,
    out: ?[*]u8,
    out_cap: usize,
) usize {
    const input = names_json[0..names_json_len];
    if (std.mem.indexOfScalar(u8, input, '[') == null) return 0; // malformed
    // Component names are identifiers, so tokenizing on JSON punctuation
    // is a faithful-enough parse for a mock.
    var names: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, input, "[]\", \t");
    while (it.next()) |tok| {
        if (n >= names.len) break;
        names[n] = tok;
        n += 1;
    }
    if (n == 0) return 0;
    // Contract v1 snprintf-style sizing: RETURN the bytes the complete
    // result needs; WRITE only up to `out_cap`, truncated at the last
    // whole id with the closing `]` reserved so the written prefix stays
    // valid JSON. NULL out (the pure sizing probe) writes nothing.
    const buf: []u8 = if (out) |p| p[0..out_cap] else &.{};
    var cur: usize = 0;
    var required: usize = 2; // "[]" — the brackets, matches or not
    var writing = buf.len >= 2;
    if (writing) {
        buf[0] = '[';
        cur = 1;
    }
    var first = true;
    outer: for (world.entities[0..world.entity_count]) |*e| {
        if (!e.alive) continue;
        for (names[0..n]) |nm| {
            if (!entityHas(e, nm)) continue :outer;
        }
        var tmp: [21]u8 = undefined; // u64 max = 20 digits, +1 comma
        var w = std.Io.Writer.fixed(&tmp);
        if (!first) w.writeByte(',') catch unreachable;
        w.print("{d}", .{e.id}) catch unreachable;
        const frag = w.buffered();
        required += frag.len;
        // Reserve one byte for `]`; a fragment that doesn't fit flips to
        // pure counting (rollback-at-last-whole-id semantics).
        if (writing and cur + frag.len <= buf.len - 1) {
            @memcpy(buf[cur..][0..frag.len], frag);
            cur += frag.len;
        } else {
            writing = false;
        }
        first = false;
    }
    if (buf.len >= 2) buf[cur] = ']';
    return required;
}

// ── contract exports: events ─────────────────────────────────────────────

export fn labelle_event_emit(
    name: [*]const u8,
    name_len: usize,
    json: [*]const u8,
    json_len: usize,
) i32 {
    if (world.event_count >= MAX_EVENTS) return -1;
    const ev = &world.events[world.event_count];
    var w = std.Io.Writer.fixed(&ev.buf);
    w.print("{s} {s}", .{ name[0..name_len], json[0..json_len] }) catch return -1;
    ev.len = w.buffered().len;
    world.event_count += 1;
    return 0;
}

export fn labelle_event_subscribe(name: [*]const u8, name_len: usize) void {
    const n = name[0..@min(name_len, EVENT_CAP)];
    // Dedup per the contract ("duplicates are deduped").
    for (world.subs[0..world.sub_count]) |*s| {
        if (std.mem.eql(u8, s.slice(), n)) return;
    }
    if (world.sub_count >= MAX_SUBS) return;
    const s = &world.subs[world.sub_count];
    @memcpy(s.buf[0..n.len], n);
    s.len = n.len;
    world.sub_count += 1;
}

export fn labelle_event_poll(out: ?[*]u8, out_cap: usize) usize {
    if (world.inbox_count == 0) return 0;
    const ev = &world.inbox[world.inbox_head];
    // Contract v1 probe pairing: NULL/cap-0 returns the NEXT entry's
    // size and consumes NOTHING — the sizing leg of the poll loop. Only
    // a real read (below) consumes, truncation included.
    const buf = out orelse return ev.len;
    if (out_cap == 0) return ev.len;
    world.inbox_head = (world.inbox_head + 1) % MAX_EVENTS;
    world.inbox_count -= 1;
    const len = @min(ev.len, out_cap);
    @memcpy(buf[0..len], ev.buf[0..len]);
    return len;
}

// ── contract exports: scene / log / time ─────────────────────────────────

export fn labelle_scene_change(name: [*]const u8, name_len: usize) i32 {
    const n = name[0..name_len];
    // "nope" plays the unknown-scene role so tests can exercise the -1 arm.
    if (n.len == 0 or std.mem.eql(u8, n, "nope")) return -1;
    const len = @min(n.len, NAME_CAP);
    @memcpy(world.scene[0..len], n[0..len]);
    world.scene_len = len;
    return 0;
}

export fn labelle_log(msg: [*]const u8, len: usize) void {
    if (world.log_count >= MAX_LOGS) return;
    const l = &world.logs[world.log_count];
    const n = @min(len, LOG_CAP);
    @memcpy(l.buf[0..n], msg[0..n]);
    l.len = n;
    world.log_count += 1;
}

export fn labelle_time_dt() f32 {
    return world.dt;
}

export fn labelle_time_dt_stamp(dt: f32) void {
    world.dt = dt;
}

// ── host-side test helpers (not part of the contract) ───────────────────

/// Force the id the next `labelle_entity_create` hands out — how tests
/// mint bit-63 u64 ids without burning through 2^63 creates first.
pub fn setNextEntityId(id: u64) void {
    world.next_id = id;
}

/// Emit toward scripts: queued into the inbox only when subscribed — the
/// engine analog of GameEvents dispatch fanning out to script subscribers.
pub fn hostEmit(name: []const u8, json: []const u8) void {
    var subscribed = false;
    for (world.subs[0..world.sub_count]) |*s| {
        if (std.mem.eql(u8, s.slice(), name)) subscribed = true;
    }
    if (!subscribed or world.inbox_count >= MAX_EVENTS) return;
    const slot = (world.inbox_head + world.inbox_count) % MAX_EVENTS;
    const ev = &world.inbox[slot];
    var w = std.Io.Writer.fixed(&ev.buf);
    w.print("{s} {s}", .{ name, json }) catch return;
    ev.len = w.buffered().len;
    world.inbox_count += 1;
}

/// Direct-call seams for the engine-parity tests — the `export fn`s are
/// not `pub`, so the suite reaches the same code through these.
pub fn createEntityDirect() u64 {
    return labelle_entity_create();
}

pub fn setComponentDirect(id: u64, name: []const u8, json: []const u8) void {
    setComponent(id, name, json);
}

pub fn setPackedDirect(id: u64, name: []const u8, buf: []const u8) i32 {
    return labelle_component_set_packed(id, name.ptr, name.len, buf.ptr, buf.len);
}

pub fn batchSetDirect(names_json: []const u8, buf: []const u8) i32 {
    return labelle_component_batch_set(names_json.ptr, names_json.len, buf.ptr, buf.len);
}

/// The stored JSON of a component, or null when entity/component is gone.
pub fn componentJson(id: u64, name: []const u8) ?[]const u8 {
    const e = world.find(id) orelse return null;
    for (e.comps[0..e.comp_count]) |*comp| {
        if (std.mem.eql(u8, comp.nameSlice(), name)) return comp.jsonSlice();
    }
    return null;
}

pub fn entityAlive(id: u64) bool {
    return world.find(id) != null;
}

pub fn aliveCount() usize {
    var n: usize = 0;
    for (world.entities[0..world.entity_count]) |*e| {
        if (e.alive) n += 1;
    }
    return n;
}

/// Did any script→host emission contain `needle`? (Entries are
/// "<name> <json>".)
pub fn eventsContain(needle: []const u8) bool {
    for (world.events[0..world.event_count]) |*ev| {
        if (std.mem.indexOf(u8, ev.slice(), needle) != null) return true;
    }
    return false;
}

/// Did any labelle_log line contain `needle`? Error-path assertions
/// (tracebacks, chunk names) go through this.
pub fn logsContain(needle: []const u8) bool {
    for (world.logs[0..world.log_count]) |*l| {
        if (std.mem.indexOf(u8, l.buf[0..l.len], needle) != null) return true;
    }
    return false;
}

/// Index of the FIRST log line containing `needle`, or null — ordering
/// assertions (controller setup/teardown sequences) go through this.
pub fn logIndexOf(needle: []const u8) ?usize {
    for (world.logs[0..world.log_count], 0..) |*l, i| {
        if (std.mem.indexOf(u8, l.buf[0..l.len], needle) != null) return i;
    }
    return null;
}

/// How many labelle_log lines contain `needle` — "logged exactly once"
/// assertions (per-handler dispatch errors) go through this.
pub fn logCount(needle: []const u8) usize {
    var n: usize = 0;
    for (world.logs[0..world.log_count]) |*l| {
        if (std.mem.indexOf(u8, l.buf[0..l.len], needle) != null) n += 1;
    }
    return n;
}

pub fn sceneName() []const u8 {
    return world.scene[0..world.scene_len];
}
