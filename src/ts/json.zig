//! The typescript sub-module's JSON codec: JSValue → bytes and bytes →
//! JSValue, in Zig — NOT JSON.stringify/JSON.parse. Two JavaScript facts
//! force the native codec (the module doc in bindings.zig carries the
//! full story): JSON.parse yields lossy f64 Numbers for every integer
//! token (a bit-63 entity id would round to the wrong entity), and
//! JSON.stringify throws on BigInt (so `{ owner: e.id }` payloads could
//! not encode at all). Everything else keeps JSON.stringify's semantics
//! JS authors expect, plus SORTED object keys so hosts and tests compare
//! payloads byte-for-byte (every backend's promise).
//!
//! Three entry points, consumed by bindings.zig's shims:
//!   - `encodeToScratch`   — one value to JSON bytes (in the shared
//!                           grow-only text scratch);
//!   - `decodeDocument`    — one complete JSON document to a JSValue;
//!   - `decodeObjectInto`  — a component JSON object assigned key-by-key
//!                           onto an EXISTING object (the `get(name,
//!                           into)` refill fast path: scalar fields cross
//!                           as immediates, zero JS allocation).
//!
//! Error protocol (shared with bindings.zig): a failing path sets a
//! pending JS exception and returns `error.JsError`; owned JSValues are
//! errdefer-freed on the way out (in Debug, JS_FreeRuntime asserts the
//! heap drained — leaks abort).
//!
//! The text scratch lives in bindings.zig next to its io sibling (one
//! growth counter serves both — the settling seam tests assert on);
//! encode output and string unescaping share it, which is safe because
//! encode and decode never run concurrently and keys are interned to
//! atoms before any nested unescape can clobber them.

const std = @import("std");
const vm_mod = @import("vm.zig");
const bindings = @import("bindings.zig");
const c = vm_mod.c;

/// "Exception already pending on the context" — the shim unwind signal
/// (bindings.zig aliases this).
pub const JsError = error{JsError};

/// Object keys per JSON object during encode (sorting buffer).
const MAX_OBJECT_KEYS = 64;

/// Encode recursion cap — the cycle guard (component payloads are a few
/// levels deep; a self-referencing object would otherwise recurse forever).
const MAX_ENCODE_DEPTH = 32;

/// Number.MAX_SAFE_INTEGER — the largest integer f64 holds exactly.
/// Integer JSON tokens at or below it decode as plain Numbers; beyond it
/// they become BigInt (the id-bearing range).
const MAX_SAFE_INTEGER: u64 = 9007199254740991;

/// The header's static-inline JS_NewInt64: int tag when it fits i32,
/// float64 otherwise (exact for |v| ≤ 2^53, which is all callers pass).
pub fn newNumberI64(v: i64) c.Value {
    if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32))
        return c.Value.int(@intCast(v));
    return c.Value.float(@floatFromInt(v));
}

// ── public entry points ──────────────────────────────────────────────────

/// Encode one value as JSON into the text scratch; the returned slice is
/// valid until the next encode/unescape.
pub fn encodeToScratch(ctx: ?*c.Context, v: c.Value) JsError![]const u8 {
    var out = Out{ .ctx = ctx };
    try encodeValue(ctx, v, &out, 0);
    return out.slice();
}

/// Decode one complete JSON document (trailing garbage throws).
pub fn decodeDocument(ctx: ?*c.Context, text: []const u8) JsError!c.Value {
    var p = Parser{ .ctx = ctx, .text = text };
    return p.parseDocument();
}

/// Decode a component JSON OBJECT by assigning each top-level key onto
/// the existing `into` object — fields absent from the JSON keep their
/// previous value (the ruby get_into REFILL semantics). SetProperty (not
/// DefineProperty) on purpose: a refill behaves like plain assignment, so
/// accessor-backed fields on user classes still work.
pub fn decodeObjectInto(ctx: ?*c.Context, text: []const u8, into: c.Value) JsError!void {
    var p = Parser{ .ctx = ctx, .text = text };
    p.skipWs();
    if (p.next() != '{') {
        _ = c.JS_ThrowSyntaxError(ctx, "labelle: component JSON is not an object");
        return error.JsError;
    }
    p.skipWs();
    if (p.peek() == '}') return;
    while (true) {
        // The key bytes live in the text scratch only until the next
        // unescape — intern them into an atom BEFORE parsing the value.
        const key = try p.parseKey();
        const key_atom = c.JS_NewAtomLen(ctx, key.ptr, key.len);
        if (key_atom == 0) return error.JsError; // JS_ATOM_NULL: OOM, thrown
        const v = p.parseValue() catch |e| {
            c.JS_FreeAtom(ctx, key_atom);
            return e;
        };
        const rc = c.JS_SetProperty(ctx, into, key_atom, v); // consumes v
        c.JS_FreeAtom(ctx, key_atom);
        if (rc < 0) return error.JsError;
        p.skipWs();
        switch (p.next()) {
            ',' => p.skipWs(),
            '}' => return,
            else => {
                _ = c.JS_ThrowSyntaxError(ctx, "labelle: malformed component JSON");
                return error.JsError;
            },
        }
    }
}

// ── encode (JSValue → bytes) ─────────────────────────────────────────────

/// Encode output builder over the grow-only text scratch.
const Out = struct {
    ctx: ?*c.Context,
    len: usize = 0,

    fn room(self: *Out, extra: usize) JsError![*]u8 {
        const buf = try bindings.text_scratch.ensure(self.ctx, self.len + extra);
        return buf + self.len;
    }

    fn byte(self: *Out, b: u8) JsError!void {
        (try self.room(1))[0] = b;
        self.len += 1;
    }

    fn bytes(self: *Out, s: []const u8) JsError!void {
        @memcpy((try self.room(s.len))[0..s.len], s);
        self.len += s.len;
    }

    fn print(self: *Out, comptime fmt: []const u8, args: anytype) JsError!void {
        // Numbers only — 40 bytes covers every i64/u64/f64 rendering.
        var tmp: [40]u8 = undefined;
        var w = std.Io.Writer.fixed(&tmp);
        w.print(fmt, args) catch unreachable;
        try self.bytes(w.buffered());
    }

    fn jsonString(self: *Out, s: []const u8) JsError!void {
        try self.byte('"');
        for (s) |ch| {
            switch (ch) {
                '"' => try self.bytes("\\\""),
                '\\' => try self.bytes("\\\\"),
                '\n' => try self.bytes("\\n"),
                '\r' => try self.bytes("\\r"),
                '\t' => try self.bytes("\\t"),
                0x08 => try self.bytes("\\b"),
                0x0C => try self.bytes("\\f"),
                0...0x07, 0x0B, 0x0E...0x1F => try self.print("\\u{x:0>4}", .{ch}),
                else => try self.byte(ch),
            }
        }
        try self.byte('"');
    }

    fn slice(self: *Out) []const u8 {
        return if (bindings.text_scratch.ptr) |p| p[0..self.len] else "";
    }
};

/// Values JSON.stringify treats as "not serializable": skipped as object
/// properties, null'd as array elements.
fn isUnserializable(ctx: ?*c.Context, v: c.Value) bool {
    return v.isUndefined() or v.tag == c.TAG_SYMBOL or c.JS_IsFunction(ctx, v);
}

/// Encode one JSValue as JSON. Objects encode with SORTED string keys —
/// property insertion order is program-dependent, and a stable encoding
/// lets hosts and tests compare payloads byte-for-byte (every backend's
/// promise). Numbers render integral-when-integral ("50", never "50.0" —
/// JS has one number type, and the other backends' integer fields must
/// survive a JS round-trip byte-exact). BigInts render as UNSIGNED 64-bit
/// decimals (mod 2^64) — they carry entity ids, and unsigned is the
/// contract's wire form (see bindings.zig's module doc).
fn encodeValue(ctx: ?*c.Context, v: c.Value, out: *Out, depth: usize) JsError!void {
    if (depth > MAX_ENCODE_DEPTH) {
        _ = c.JS_ThrowTypeError(ctx, "labelle: json_encode: nesting too deep (cyclic value?)");
        return error.JsError;
    }
    switch (v.tag) {
        c.TAG_NULL => try out.bytes("null"),
        c.TAG_BOOL => try out.bytes(if (v.u.int32 != 0) "true" else "false"),
        c.TAG_INT => try out.print("{d}", .{v.u.int32}),
        c.TAG_FLOAT64 => {
            const f = v.u.float64;
            if (std.math.isNan(f) or std.math.isInf(f)) {
                _ = c.JS_ThrowTypeError(ctx, "labelle: json_encode: non-finite number");
                return error.JsError;
            }
            // Integral doubles print as integers: the fixed-point the
            // other backends' int fields need to round-trip byte-exact.
            const max_exact: f64 = @floatFromInt(MAX_SAFE_INTEGER);
            if (@floor(f) == f and @abs(f) <= max_exact) {
                try out.print("{d}", .{@as(i64, @intFromFloat(f))});
            } else {
                try out.print("{d}", .{f});
            }
        },
        c.TAG_BIG_INT, c.TAG_SHORT_BIG_INT => {
            var i: i64 = 0;
            if (c.JS_ToInt64Ext(ctx, &i, v) < 0) return error.JsError; // wraps mod 2^64
            try out.print("{d}", .{@as(u64, @bitCast(i))});
        },
        c.TAG_STRING, c.TAG_STRING_ROPE => {
            var len: usize = 0;
            const p = c.JS_ToCStringLen2(ctx, &len, v, false) orelse return error.JsError;
            defer c.JS_FreeCString(ctx, p);
            try out.jsonString(p[0..len]);
        },
        c.TAG_OBJECT => {
            if (c.JS_IsArray(v)) {
                try encodeArray(ctx, v, out, depth);
            } else if (c.JS_IsFunction(ctx, v)) {
                _ = c.JS_ThrowTypeError(ctx, "labelle: json_encode: cannot encode a function");
                return error.JsError;
            } else {
                try encodeObject(ctx, v, out, depth);
            }
        },
        else => {
            _ = c.JS_ThrowTypeError(ctx, "labelle: json_encode: unsupported value type");
            return error.JsError;
        },
    }
}

fn encodeArray(ctx: ?*c.Context, v: c.Value, out: *Out, depth: usize) JsError!void {
    var len: i64 = 0;
    if (c.JS_GetLength(ctx, v, &len) < 0) return error.JsError;
    if (len > std.math.maxInt(u32)) {
        _ = c.JS_ThrowRangeError(ctx, "labelle: json_encode: array too long");
        return error.JsError;
    }
    try out.byte('[');
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        if (i > 0) try out.byte(',');
        const elem = c.JS_GetPropertyUint32(ctx, v, @intCast(i));
        if (elem.isException()) return error.JsError;
        defer c.JS_FreeValue(ctx, elem);
        if (isUnserializable(ctx, elem)) {
            try out.bytes("null"); // JSON.stringify's array-slot rule
        } else {
            try encodeValue(ctx, elem, out, depth + 1);
        }
    }
    try out.byte(']');
}

fn encodeObject(ctx: ?*c.Context, v: c.Value, out: *Out, depth: usize) JsError!void {
    var tab: ?[*]c.PropertyEnum = null;
    var count: u32 = 0;
    if (c.JS_GetOwnPropertyNames(ctx, &tab, &count, v, c.GPN_STRING_MASK | c.GPN_ENUM_ONLY) < 0)
        return error.JsError;
    defer c.JS_FreePropertyEnum(ctx, tab, count);
    if (count > MAX_OBJECT_KEYS) {
        _ = c.JS_ThrowRangeError(ctx, "labelle: json_encode: too many object keys");
        return error.JsError;
    }

    // Materialize the key names (JS_AtomToCStringLen copies — free each),
    // then insertion-sort an order table by name.
    var names: [MAX_OBJECT_KEYS][]const u8 = undefined;
    var cstrs: [MAX_OBJECT_KEYS]?[*:0]const u8 = undefined;
    var filled: usize = 0;
    defer for (cstrs[0..filled]) |p| c.JS_FreeCString(ctx, p);
    while (filled < count) {
        var nlen: usize = 0;
        const p = c.JS_AtomToCStringLen(ctx, &nlen, tab.?[filled].atom) orelse return error.JsError;
        cstrs[filled] = p;
        names[filled] = p[0..nlen];
        filled += 1;
    }
    var order: [MAX_OBJECT_KEYS]usize = undefined;
    for (0..count) |k| order[k] = k;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const oi = order[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, names[order[j - 1]], names[oi]) == .gt) : (j -= 1) {
            order[j] = order[j - 1];
        }
        order[j] = oi;
    }

    try out.byte('{');
    var emitted: usize = 0;
    for (order[0..count]) |oi| {
        const pv = c.JS_GetProperty(ctx, v, tab.?[oi].atom);
        if (pv.isException()) return error.JsError;
        defer c.JS_FreeValue(ctx, pv);
        // JSON.stringify's object rule: undefined/function/symbol
        // properties are simply absent from the output.
        if (isUnserializable(ctx, pv)) continue;
        if (emitted > 0) try out.byte(',');
        try out.jsonString(names[oi]);
        try out.byte(':');
        try encodeValue(ctx, pv, out, depth + 1);
        emitted += 1;
    }
    try out.byte('}');
}

// ── decode (bytes → JSValue) ─────────────────────────────────────────────

/// Recursive-descent JSON reader producing JS values: objects become
/// plain objects (keys defined, not assigned — a "__proto__" key can
/// never pollute prototypes), arrays become Arrays, and INTEGER-LOOKING
/// tokens (all digits, optional '-') build with WRAPPING u64 arithmetic:
/// exact Numbers up to 2^53, BigInt beyond (the id-bearing range — a
/// bit-63 entity id in a payload lands bit-exact on the same BigInt the
/// raw shims hand out; tokens past 20 digits keep wrapping mod 2^64, the
/// lua codec's documented semantics). True float tokens (fractions,
/// exponents) parse as f64. Malformed input throws SyntaxError.
const Parser = struct {
    ctx: ?*c.Context,
    text: []const u8,
    pos: usize = 0,

    fn parseDocument(p: *Parser) JsError!c.Value {
        const v = try p.parseValue();
        p.skipWs();
        if (p.pos < p.text.len) {
            c.JS_FreeValue(p.ctx, v);
            return p.fail("labelle: json_decode: trailing garbage");
        }
        return v;
    }

    fn fail(p: *Parser, comptime msg: [:0]const u8) JsError {
        _ = c.JS_ThrowSyntaxError(p.ctx, msg.ptr);
        return error.JsError;
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

    /// An object key: '"' string '"' ':' — returns the UNESCAPED bytes
    /// (borrowed from the text scratch until the next unescape; callers
    /// intern them before recursing).
    fn parseKey(p: *Parser) JsError![]const u8 {
        p.skipWs();
        if (p.peek() != '"') return p.fail("labelle: json_decode: expected object key");
        const key = try p.parseStringBytes();
        p.skipWs();
        if (p.next() != ':') return p.fail("labelle: json_decode: expected ':'");
        return key;
    }

    fn parseValue(p: *Parser) JsError!c.Value {
        p.skipWs();
        switch (p.peek()) {
            '{' => {
                p.pos += 1;
                const obj = c.JS_NewObject(p.ctx);
                if (obj.isException()) return error.JsError;
                errdefer c.JS_FreeValue(p.ctx, obj);
                p.skipWs();
                if (p.peek() == '}') {
                    p.pos += 1;
                    return obj;
                }
                while (true) {
                    const key = try p.parseKey();
                    const key_atom = c.JS_NewAtomLen(p.ctx, key.ptr, key.len);
                    if (key_atom == 0) return error.JsError; // OOM, thrown
                    const v = p.parseValue() catch |e| {
                        c.JS_FreeAtom(p.ctx, key_atom);
                        return e;
                    };
                    // DefineProperty (consumes v): decode must create
                    // plain data properties — JSON.parse's own rule, and
                    // the "__proto__" pollution guard.
                    const rc = c.JS_DefinePropertyValue(p.ctx, obj, key_atom, v, c.PROP_C_W_E);
                    c.JS_FreeAtom(p.ctx, key_atom);
                    if (rc < 0) return error.JsError;
                    p.skipWs();
                    switch (p.next()) {
                        ',' => {},
                        '}' => return obj,
                        else => return p.fail("labelle: json_decode: expected ',' or '}'"),
                    }
                }
            },
            '[' => {
                p.pos += 1;
                const arr = c.JS_NewArray(p.ctx);
                if (arr.isException()) return error.JsError;
                errdefer c.JS_FreeValue(p.ctx, arr);
                p.skipWs();
                if (p.peek() == ']') {
                    p.pos += 1;
                    return arr;
                }
                var idx: u32 = 0;
                while (true) {
                    const v = try p.parseValue();
                    if (c.JS_SetPropertyUint32(p.ctx, arr, idx, v) < 0) return error.JsError;
                    idx += 1;
                    p.skipWs();
                    switch (p.next()) {
                        ',' => {},
                        ']' => return arr,
                        else => return p.fail("labelle: json_decode: expected ',' or ']'"),
                    }
                }
            },
            '"' => {
                const s = try p.parseStringBytes();
                const v = c.JS_NewStringLen(p.ctx, s.ptr, s.len);
                if (v.isException()) return error.JsError;
                return v;
            },
            't' => {
                try p.expectWord("true");
                return c.Value.boolean(true);
            },
            'f' => {
                try p.expectWord("false");
                return c.Value.boolean(false);
            },
            'n' => {
                try p.expectWord("null");
                return c.Value.null_;
            },
            else => return p.parseNumber(),
        }
    }

    fn expectWord(p: *Parser, comptime w: []const u8) JsError!void {
        if (p.pos + w.len > p.text.len or !std.mem.eql(u8, p.text[p.pos..][0..w.len], w))
            return p.fail("labelle: json_decode: malformed literal");
        p.pos += w.len;
    }

    /// String contents, unescaped into the text scratch (valid until the
    /// next unescape/encode). `pos` sits on the opening quote.
    fn parseStringBytes(p: *Parser) JsError![]const u8 {
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
            return p.fail("labelle: json_decode: unterminated string");
        if (!has_escape) {
            p.pos = end + 1;
            return p.text[start..end];
        }
        const raw = p.text[start..end];
        const buf = try bindings.text_scratch.ensure(p.ctx, raw.len);
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
            if (i >= raw.len) return p.fail("labelle: json_decode: bad escape");
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
                    if (i + 4 > raw.len) return p.fail("labelle: json_decode: bad \\u escape");
                    const cp = std.fmt.parseInt(u16, raw[i..][0..4], 16) catch
                        return p.fail("labelle: json_decode: bad \\u escape");
                    i += 4;
                    out_len += std.unicode.utf8Encode(cp, buf[out_len..][0..4]) catch
                        return p.fail("labelle: json_decode: bad \\u escape");
                },
                else => return p.fail("labelle: json_decode: bad escape"),
            }
        }
        p.pos = end + 1;
        return buf[0..out_len];
    }

    fn parseNumber(p: *Parser) JsError!c.Value {
        const start = p.pos;
        while (p.pos < p.text.len) : (p.pos += 1) {
            switch (p.text[p.pos]) {
                '-', '+', '.', 'e', 'E', '0'...'9' => {},
                else => break,
            }
        }
        const tok = p.text[start..p.pos];
        if (tok.len == 0) return p.fail("labelle: json_decode: bad number");
        const neg = tok[0] == '-';
        const digits = if (neg) tok[1..] else tok;
        var all_digits = digits.len > 0;
        for (digits) |d| {
            if (d < '0' or d > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            // Wrapping u64 accumulate; `wrapped` distinguishes "exceeded
            // 2^64" (keep wrapping, lua semantics) from merely "past
            // 2^53" (exact in u64, but not in an f64 Number → BigInt).
            var acc: u64 = 0;
            var wrapped = false;
            for (digits) |d| {
                const mul = @mulWithOverflow(acc, 10);
                const add = @addWithOverflow(mul[0], @as(u64, d - '0'));
                if (mul[1] != 0 or add[1] != 0) wrapped = true;
                acc = add[0];
            }
            if (!wrapped and acc <= MAX_SAFE_INTEGER) {
                const mag: i64 = @intCast(acc);
                return newNumberI64(if (neg) -mag else mag);
            }
            const bits: u64 = if (neg) 0 -% acc else acc;
            const v = if (neg)
                c.JS_NewBigInt64(p.ctx, @bitCast(bits))
            else
                c.JS_NewBigUint64(p.ctx, bits);
            if (v.isException()) return error.JsError;
            return v;
        }
        const f = std.fmt.parseFloat(f64, tok) catch
            return p.fail("labelle: json_decode: bad number");
        return c.Value.float(f);
    }
};
