//! TypeScript declare-mode extraction core (labelle-declare-ts — the
//! lua/ruby runners' twin; see tools/declare/extract.zig and
//! tools/declare-ruby/extract.zig for the reference semantics, and
//! RFC-LANGUAGE-PLUGINS rev 20 for the design).
//!
//! Runs each declaration file — the EMITTED `.js` under RFC rev 20 option
//! (b): the assembler transpiles `components/*.ts` + `events/*.ts` FIRST and
//! hands this evaluator the output, so the tool knows NOTHING about tsc — as
//! its own ES MODULE against the declare stub `labelle`
//! (tools/declare-ts/declare_prelude.js): `labelle.component(...)` and
//! `labelle.event(...)` record schema declarations, `labelle.id` is the u64
//! field marker. One DSL, two consumers: at game runtime the SAME lines yield
//! a component ref / the frozen event-name string (src/ts/prelude.js); at
//! generate time, run through this extractor, they yield the schema JSON the
//! assembler codegens real Zig components and events from — byte-identical to
//! the lua/ruby runners' output.
//!
//! Isolation model — SIMPLER than both interpreted twins. The lua runner
//! builds a fresh stub `_ENV` per chunk inside one VM; the ruby runner opens
//! a fresh mrb_state per chunk AND threads a constant ledger across them (its
//! one shared VM makes a later file's `labelle.on(HungerFeed)` reference an
//! earlier file's top-level constant). TypeScript needs NEITHER: each file is
//! its own ES module (JS_EVAL_TYPE_MODULE), so top-level bindings are
//! module-private by the language spec — two files never collide, and NO file
//! can see another's top-level constants, so there is nothing to thread. Every
//! module runs in ONE context; the prelude installs the stub + recorder on
//! globalThis once, and modules accumulate into it. Scripts reference declared
//! names by STRING, never by a shared constant (imports are refused in this
//! engine), so the ledger the ruby runner needs has no TypeScript analog.
//!
//! Separate from src/ts/vm.zig on purpose (the lua/ruby extract.zig rule):
//! vm.zig's error paths log through the Script Runtime Contract's
//! `labelle_log` extern, which only the HOST GAME binary exports — a
//! standalone tool linking vm.zig would not link. This file re-declares the
//! (smaller) slice of the quickjs-ng C API it touches with no contract
//! dependency; the quickjs objects themselves come from whichever module
//! compiled them into the enclosing binary (the exe root embeds them via
//! build.zig; the test binary reuses the ones the typescript-language
//! `labelle_scripting` module already carries).
//!
//! Byte formatting lives HERE, not in the prelude: float defaults render
//! through the host libc's `snprintf("%.14g", …)` — byte-identical to the lua
//! runner, which formats through the same libc — with floatness forcing
//! ("1.0", not "1"); integers as decimals; strings through the shared escape
//! set; the envelope assembled like the lua/ruby emitters (the "events" key
//! present ONLY when an event was declared, so event-free schemas stay
//! byte-identical to what pre-events assemblers always saw). The prelude only
//! CLASSIFIES and stores raw values — it never renders a number, so `%.14g`
//! stays a single host-libc call rather than a reimplementation in JS.
//!
//! Error policy: extraction is a BUILD step — the first module that throws (a
//! malformed declaration, a syntax error) aborts with a file-and-line bearing
//! message (`Outcome.failure`). The thrown Error's `.stack` carries the
//! declaration's call-site frame ("<path>:<line>") because each module is
//! evaluated under its own path as the filename.

const std = @import("std");

/// libc `snprintf`, for byte-identical float formatting with the lua runner
/// (which formats floats through `string.format("%.14g", …)` — the same
/// host libc). Variadic; called only with the constant "%.14g" and one f64.
extern fn snprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ...) c_int;

/// Hand-declared quickjs-ng 0.15 C API — the slice this extractor touches
/// (the src/ts/vm.zig pattern: real exported symbols, JSValue mirrored as the
/// {union, i64 tag} struct pinned by src/ts/abi_check.c under
/// JS_NAN_BOXING=0). `mrb_state`'s twin, JSRuntime/JSContext, stay opaque.
const c = struct {
    pub const Runtime = opaque {};
    pub const Context = opaque {};

    // enum JS_TAG_* (quickjs.h). Negative tags are the reference-counted ones.
    pub const TAG_BIG_INT: i64 = -9;
    pub const TAG_STRING: i64 = -7;
    pub const TAG_STRING_ROPE: i64 = -6;
    pub const TAG_OBJECT: i64 = -1;
    pub const TAG_INT: i64 = 0;
    pub const TAG_BOOL: i64 = 1;
    pub const TAG_NULL: i64 = 2;
    pub const TAG_UNDEFINED: i64 = 3;
    pub const TAG_EXCEPTION: i64 = 6;
    pub const TAG_SHORT_BIG_INT: i64 = 7;
    pub const TAG_FLOAT64: i64 = 8;

    // JS_Eval flags.
    pub const EVAL_TYPE_GLOBAL: c_int = 0;
    pub const EVAL_TYPE_MODULE: c_int = 1 << 0;

    // JS_PromiseState results.
    pub const PROMISE_PENDING: c_int = 0;
    pub const PROMISE_REJECTED: c_int = 2;

    pub const Value = extern struct {
        u: extern union {
            int32: i32,
            float64: f64,
            ptr: ?*anyopaque,
        },
        tag: i64,

        pub fn isException(v: Value) bool {
            return v.tag == TAG_EXCEPTION;
        }
        pub fn isString(v: Value) bool {
            return v.tag == TAG_STRING or v.tag == TAG_STRING_ROPE;
        }
        pub fn isObject(v: Value) bool {
            return v.tag == TAG_OBJECT;
        }
        pub fn isBigInt(v: Value) bool {
            return v.tag == TAG_BIG_INT or v.tag == TAG_SHORT_BIG_INT;
        }
    };

    pub extern fn JS_NewRuntime() ?*Runtime;
    pub extern fn JS_FreeRuntime(rt: ?*Runtime) void;
    pub extern fn JS_NewContext(rt: ?*Runtime) ?*Context;
    pub extern fn JS_FreeContext(ctx: ?*Context) void;
    pub extern fn JS_GetRuntime(ctx: ?*Context) ?*Runtime;
    pub extern fn JS_ExecutePendingJob(rt: ?*Runtime, pctx: *?*Context) c_int;

    // NOTE: JS_Eval requires input[input_len] == 0 — sources arrive as
    // sentinel-terminated copies for exactly this reason.
    pub extern fn JS_Eval(ctx: ?*Context, input: [*]const u8, input_len: usize, filename: [*:0]const u8, eval_flags: c_int) Value;
    pub extern fn JS_PromiseState(ctx: ?*Context, promise: Value) c_int;
    pub extern fn JS_PromiseResult(ctx: ?*Context, promise: Value) Value;

    pub extern fn JS_GetException(ctx: ?*Context) Value;
    pub extern fn JS_HasException(ctx: ?*Context) bool;

    pub extern fn JS_FreeValue(ctx: ?*Context, v: Value) void;

    pub extern fn JS_GetGlobalObject(ctx: ?*Context) Value;
    pub extern fn JS_GetPropertyStr(ctx: ?*Context, this_obj: Value, prop: [*:0]const u8) Value;
    pub extern fn JS_SetPropertyStr(ctx: ?*Context, this_obj: Value, prop: [*:0]const u8, val: Value) c_int;
    pub extern fn JS_GetPropertyUint32(ctx: ?*Context, this_obj: Value, idx: u32) Value;
    pub extern fn JS_GetLength(ctx: ?*Context, obj: Value, pres: *i64) c_int;

    pub extern fn JS_NewStringLen(ctx: ?*Context, str: [*]const u8, len: usize) Value;
    pub extern fn JS_ToCStringLen2(ctx: ?*Context, plen: ?*usize, val: Value, cesu8: bool) ?[*:0]const u8;
    pub extern fn JS_FreeCString(ctx: ?*Context, ptr: ?[*:0]const u8) void;

    pub extern fn JS_ToFloat64(ctx: ?*Context, pres: *f64, val: Value) c_int;
    pub extern fn JS_ToInt64Ext(ctx: ?*Context, pres: *i64, val: Value) c_int;
};

const prelude_source = @embedFile("declare_prelude.js");

/// One declaration file to scan: `path` names it in errors and is the module
/// filename (so stack frames read against it); `source` is the emitted JS.
pub const Input = struct {
    path: []const u8,
    source: []const u8,
};

/// Either the schema JSON (one compact line, no trailing newline) or the
/// first failure, as a printable file-and-line bearing message. The active
/// slice is owned by the caller (allocated with the `run` allocator).
pub const Outcome = union(enum) {
    schema: []u8,
    failure: []u8,

    pub fn deinit(self: Outcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .schema, .failure => |s| allocator.free(s),
        }
    }
};

pub const Error = error{
    /// JS_NewRuntime/JS_NewContext failed (OOM inside quickjs).
    JsStateInit,
    /// The embedded declare prelude failed to load or run, or the recorder it
    /// installs is missing/malformed — an internal bug in this tool, never a
    /// user-script problem.
    DeclarePrelude,
    OutOfMemory,
};

/// Borrowed C-string view of a JS string value's UTF-8 bytes, dup'd into
/// `allocator`. Caller owns the returned slice. Null on a non-string /
/// conversion failure.
fn dupJsString(allocator: std.mem.Allocator, ctx: ?*c.Context, v: c.Value) !?[]u8 {
    var len: usize = 0;
    const cs = c.JS_ToCStringLen2(ctx, &len, v, false) orelse return null;
    defer c.JS_FreeCString(ctx, cs);
    return try allocator.dupe(u8, cs[0..len]);
}

/// Run every input as its own ES module against the declare stub and return
/// the schema JSON — or the first failure. See the module doc for semantics.
pub fn run(allocator: std.mem.Allocator, inputs: []const Input) Error!Outcome {
    const rt = c.JS_NewRuntime() orelse return error.JsStateInit;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.JsStateInit;
    defer c.JS_FreeContext(ctx);

    // Install the declare prelude as a global chunk (its explicit
    // `globalThis.*` exports must land where module scripts see them).
    {
        const src = try allocator.dupeZ(u8, prelude_source);
        defer allocator.free(src);
        const ret = c.JS_Eval(ctx, src.ptr, prelude_source.len, "labelle/declare_prelude.js", c.EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(ctx, ret);
        if (ret.isException()) return error.DeclarePrelude;
    }

    for (inputs) |input| {
        if (try runModule(allocator, ctx, rt, input)) |failure|
            return .{ .failure = failure };
    }

    return emitSchema(allocator, ctx);
}

/// Evaluate one input as an ES module. Returns a failure message
/// (allocator-owned) when the module threw, null when it ran clean.
fn runModule(
    allocator: std.mem.Allocator,
    ctx: ?*c.Context,
    rt: ?*c.Runtime,
    input: Input,
) Error!?[]u8 {
    // Stamp the current declaration file so the prelude attributes duplicate
    // detection to it (globalThis.__labelle_declare_file — the ruby
    // __declare_begin twin).
    setDeclareFile(ctx, input.path);

    const src = try allocator.dupeZ(u8, input.source);
    defer allocator.free(src);

    var namebuf: [512]u8 = undefined;
    const n = @min(input.path.len, namebuf.len - 1);
    @memcpy(namebuf[0..n], input.path[0..n]);
    namebuf[n] = 0;
    const filename: [*:0]const u8 = @ptrCast(&namebuf);

    // Module evaluation is spec'd async: a throwing body lands in the returned
    // promise's REJECTION (settled synchronously for bodies without top-level
    // await), while parse/link errors come back as a plain exception. Handle
    // both, mirroring src/ts/vm.zig's loadScript.
    const ret = c.JS_Eval(ctx, src.ptr, input.source.len, filename, c.EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, ret);
    drainJobs(ctx, rt);

    if (ret.isException()) {
        const exc = c.JS_GetException(ctx); // owned; clears the slot
        defer c.JS_FreeValue(ctx, exc);
        return try formatFailure(allocator, ctx, input.path, exc);
    }
    switch (c.JS_PromiseState(ctx, ret)) {
        c.PROMISE_REJECTED => {
            const err = c.JS_PromiseResult(ctx, ret); // owned
            defer c.JS_FreeValue(ctx, err);
            return try formatFailure(allocator, ctx, input.path, err);
        },
        c.PROMISE_PENDING => {
            // Top-level await: a declaration file that never finishes
            // evaluating cannot be extracted. Refuse deterministically.
            return try std.fmt.allocPrint(
                allocator,
                "labelle-declare-ts: {s}: top-level await is not supported in a declaration file",
                .{input.path},
            );
        },
        else => return null, // fulfilled (evaluated clean)
    }
}

/// globalThis.__labelle_declare_file = path.
fn setDeclareFile(ctx: ?*c.Context, path: []const u8) void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const v = c.JS_NewStringLen(ctx, path.ptr, path.len);
    _ = c.JS_SetPropertyStr(ctx, global, "__labelle_declare_file", v); // consumes v
}

/// Run queued promise jobs (microtasks) to completion — module evaluation
/// enqueues them. Errors here are job-machinery only; a throwing declaration
/// surfaces through the promise rejection above, so this is best-effort.
fn drainJobs(ctx: ?*c.Context, rt: ?*c.Runtime) void {
    while (true) {
        var out_ctx: ?*c.Context = null;
        const rc = c.JS_ExecutePendingJob(rt, &out_ctx);
        if (rc == 0) return;
        if (rc < 0) {
            // Clear any pending exception so it can't masquerade as a later
            // module's error.
            if (c.JS_HasException(ctx)) c.JS_FreeValue(ctx, c.JS_GetException(ctx));
        }
    }
}

// ── schema emission (ALL byte formatting lives here) ────────────────────────

/// JSON-escape one string's bytes into `out`, matching the lua/ruby preludes'
/// escape set exactly: the named escapes, \u%04x for other control bytes
/// (< 0x20 and 0x7f), raw passthrough otherwise so UTF-8 sequences survive.
fn quote(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) Error!void {
    try out.append(allocator, '"');
    for (s) |b| {
        switch (b) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (b < 0x20 or b == 0x7f) {
                    var buf: [8]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{b}) catch unreachable;
                    try out.appendSlice(allocator, hex);
                } else {
                    try out.append(allocator, b);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

/// One f64 as a JSON float: `%.14g` through the host libc, then forced to
/// carry its floatness ("1.0", not "1") — byte-identical to the lua runner's
/// number_json for floats. Non-finite / out-of-range values were rejected by
/// the prelude's classify.
fn appendFloat(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: f64) Error!void {
    var buf: [64]u8 = undefined;
    const n = snprintf(&buf, buf.len, "%.14g", v);
    if (n <= 0) return error.DeclarePrelude;
    const s = buf[0..@intCast(n)];
    try out.appendSlice(allocator, s);
    var has_dot_or_exp = false;
    for (s) |ch| {
        if (ch == '.' or ch == 'e' or ch == 'E') {
            has_dot_or_exp = true;
            break;
        }
    }
    if (!has_dot_or_exp) try out.appendSlice(allocator, ".0");
}

/// One number-valued JSValue as JSON, classifying by its tag the way the
/// runtime distinguishes them: a BigInt renders as an integer decimal, any
/// other number as a float (`%.14g` + floatness). Used for vec2 axes, where a
/// mixed float/integer pair is still one vec2.
fn appendNumberValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ctx: ?*c.Context, v: c.Value) Error!void {
    if (v.isBigInt()) {
        var i: i64 = 0;
        _ = c.JS_ToInt64Ext(ctx, &i, v);
        var buf: [24]u8 = undefined;
        try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
    } else {
        var f: f64 = 0;
        _ = c.JS_ToFloat64(ctx, &f, v);
        try appendFloat(out, allocator, f);
    }
}

/// Emit one field's `"default"` JSON given its type string and raw value.
fn appendDefault(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ctx: ?*c.Context,
    field_type: []const u8,
    value: c.Value,
) Error!void {
    if (std.mem.eql(u8, field_type, "u64")) {
        try out.appendSlice(allocator, "0");
    } else if (std.mem.eql(u8, field_type, "bool")) {
        try out.appendSlice(allocator, if (value.tag == c.TAG_BOOL and value.u.int32 != 0) "true" else "false");
    } else if (std.mem.eql(u8, field_type, "i32")) {
        var i: i64 = 0;
        _ = c.JS_ToInt64Ext(ctx, &i, value);
        var buf: [24]u8 = undefined;
        try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
    } else if (std.mem.eql(u8, field_type, "f32")) {
        var f: f64 = 0;
        _ = c.JS_ToFloat64(ctx, &f, value);
        try appendFloat(out, allocator, f);
    } else if (std.mem.eql(u8, field_type, "str")) {
        const s = (try dupJsString(allocator, ctx, value)) orelse return error.DeclarePrelude;
        defer allocator.free(s);
        try quote(out, allocator, s);
    } else if (std.mem.eql(u8, field_type, "vec2")) {
        const x = c.JS_GetPropertyStr(ctx, value, "x");
        defer c.JS_FreeValue(ctx, x);
        const y = c.JS_GetPropertyStr(ctx, value, "y");
        defer c.JS_FreeValue(ctx, y);
        try out.appendSlice(allocator, "{\"x\":");
        try appendNumberValue(out, allocator, ctx, x);
        try out.appendSlice(allocator, ",\"y\":");
        try appendNumberValue(out, allocator, ctx, y);
        try out.append(allocator, '}');
    } else {
        return error.DeclarePrelude; // an unknown type from the prelude
    }
}

/// Emit one kind's fields array ("[{...},{...}]") from the JS `fields` array.
fn appendFields(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ctx: ?*c.Context,
    fields: c.Value,
) Error!void {
    try out.append(allocator, '[');
    var flen: i64 = 0;
    if (c.JS_GetLength(ctx, fields, &flen) < 0) return error.DeclarePrelude;
    var j: u32 = 0;
    while (j < flen) : (j += 1) {
        const field = c.JS_GetPropertyUint32(ctx, fields, j);
        defer c.JS_FreeValue(ctx, field);
        if (!field.isObject()) return error.DeclarePrelude;

        const name_v = c.JS_GetPropertyStr(ctx, field, "name");
        defer c.JS_FreeValue(ctx, name_v);
        const type_v = c.JS_GetPropertyStr(ctx, field, "type");
        defer c.JS_FreeValue(ctx, type_v);
        const value_v = c.JS_GetPropertyStr(ctx, field, "value");
        defer c.JS_FreeValue(ctx, value_v);

        const fname = (try dupJsString(allocator, ctx, name_v)) orelse return error.DeclarePrelude;
        defer allocator.free(fname);
        const ftype = (try dupJsString(allocator, ctx, type_v)) orelse return error.DeclarePrelude;
        defer allocator.free(ftype);

        if (j > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"name\":");
        try quote(out, allocator, fname);
        try out.appendSlice(allocator, ",\"type\":\"");
        try out.appendSlice(allocator, ftype);
        try out.appendSlice(allocator, "\",\"default\":");
        try appendDefault(out, allocator, ctx, ftype, value_v);
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
}

/// Read the prelude's globalThis.__labelle_components / __labelle_events and
/// assemble the schema JSON. This side owns the envelope so it is
/// byte-identical to the lua/ruby emitters — including the events rule: the
/// "events" key exists ONLY when at least one event was declared.
fn emitSchema(allocator: std.mem.Allocator, ctx: ?*c.Context) Error!Outcome {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    const components = c.JS_GetPropertyStr(ctx, global, "__labelle_components");
    defer c.JS_FreeValue(ctx, components);
    const events = c.JS_GetPropertyStr(ctx, global, "__labelle_events");
    defer c.JS_FreeValue(ctx, events);
    if (!components.isObject() or !events.isObject()) return error.DeclarePrelude;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"components\":[");
    var clen: i64 = 0;
    if (c.JS_GetLength(ctx, components, &clen) < 0) return error.DeclarePrelude;
    var i: u32 = 0;
    while (i < clen) : (i += 1) {
        const item = c.JS_GetPropertyUint32(ctx, components, i);
        defer c.JS_FreeValue(ctx, item);
        if (!item.isObject()) return error.DeclarePrelude;

        const name_v = c.JS_GetPropertyStr(ctx, item, "name");
        defer c.JS_FreeValue(ctx, name_v);
        const persist_v = c.JS_GetPropertyStr(ctx, item, "persist");
        defer c.JS_FreeValue(ctx, persist_v);
        const fields = c.JS_GetPropertyStr(ctx, item, "fields");
        defer c.JS_FreeValue(ctx, fields);

        const name = (try dupJsString(allocator, ctx, name_v)) orelse return error.DeclarePrelude;
        defer allocator.free(name);
        const persist = (try dupJsString(allocator, ctx, persist_v)) orelse return error.DeclarePrelude;
        defer allocator.free(persist);

        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"name\":");
        try quote(&out, allocator, name);
        try out.appendSlice(allocator, ",\"persist\":\"");
        try out.appendSlice(allocator, persist);
        try out.appendSlice(allocator, "\",\"fields\":");
        try appendFields(&out, allocator, ctx, fields);
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');

    var elen: i64 = 0;
    if (c.JS_GetLength(ctx, events, &elen) < 0) return error.DeclarePrelude;
    if (elen > 0) {
        try out.appendSlice(allocator, ",\"events\":[");
        var k: u32 = 0;
        while (k < elen) : (k += 1) {
            const item = c.JS_GetPropertyUint32(ctx, events, k);
            defer c.JS_FreeValue(ctx, item);
            if (!item.isObject()) return error.DeclarePrelude;

            const name_v = c.JS_GetPropertyStr(ctx, item, "name");
            defer c.JS_FreeValue(ctx, name_v);
            const fields = c.JS_GetPropertyStr(ctx, item, "fields");
            defer c.JS_FreeValue(ctx, fields);

            const name = (try dupJsString(allocator, ctx, name_v)) orelse return error.DeclarePrelude;
            defer allocator.free(name);

            if (k > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, "{\"name\":");
            try quote(&out, allocator, name);
            try out.appendSlice(allocator, ",\"fields\":");
            try appendFields(&out, allocator, ctx, fields);
            try out.append(allocator, '}');
        }
        try out.append(allocator, ']');
    }
    try out.append(allocator, '}');

    return .{ .schema = try out.toOwnedSlice(allocator) };
}

// ── failure formatting ──────────────────────────────────────────────────────

/// Format one rejected/thrown error value as the failure message:
/// `labelle-declare-ts: <path>[:<line>]: <Error>: <message>`. The error's
/// ToString is "<Name>: <message>"; if its `.stack` carries a frame in the
/// declaration file, the "<path>:<line>" location is grafted on the way the
/// lua/ruby runners graft theirs. Defensive: a pathological error degrades to
/// a bare class+message.
fn formatFailure(allocator: std.mem.Allocator, ctx: ?*c.Context, path: []const u8, exc: c.Value) Error![]u8 {
    // ToString(exc): "TypeError: <message>" for Error objects.
    const text = (try dupJsString(allocator, ctx, exc)) orelse
        try allocator.dupe(u8, "(unprintable error)");
    defer allocator.free(text);

    var location: ?[]const u8 = null;
    var stack_owned: ?[]u8 = null;
    defer if (stack_owned) |s| allocator.free(s);
    if (exc.isObject()) {
        const stack_v = c.JS_GetPropertyStr(ctx, exc, "stack");
        defer c.JS_FreeValue(ctx, stack_v);
        if (stack_v.isString()) {
            if (try dupJsString(allocator, ctx, stack_v)) |stack| {
                stack_owned = stack;
                location = findLocation(stack, path);
            }
        }
    }

    if (location) |loc| {
        return try std.fmt.allocPrint(allocator, "labelle-declare-ts: {s}: {s}", .{ loc, text });
    }
    return try std.fmt.allocPrint(allocator, "labelle-declare-ts: {s}: {s}", .{ path, text });
}

/// Find "<path>:<line>" in a quickjs stack (frames read
/// "    at <fn> (<path>:<line>:<col>)"). Returns a slice into `stack` spanning
/// the path plus its trailing ":<digits>", or null when no frame matches.
fn findLocation(stack: []const u8, path: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, stack, search_from, path)) |at| {
        const after = at + path.len;
        if (after < stack.len and stack[after] == ':') {
            var end = after + 1;
            while (end < stack.len and std.ascii.isDigit(stack[end])) end += 1;
            if (end > after + 1) return stack[at..end];
        }
        search_from = after;
    }
    return null;
}
