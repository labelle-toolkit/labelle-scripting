//! Ruby declare-mode extraction core (labelle-declare-ruby — the lua
//! runner's twin; see tools/declare/extract.zig for the reference
//! semantics and RFC-LANGUAGE-PLUGINS revs 6-7 / labelle-engine#237 for
//! the design).
//!
//! Runs each script CHUNK BODY — never init/update/deinit, never
//! controller lifecycles — against the declare stub `Labelle`
//! (tools/declare-ruby/declare_prelude.rb): `Labelle.component(...)`
//! records a schema declaration, every other `Labelle.*` (and the runtime
//! API's classes) is a sentinel-returning no-op. One DSL, two consumers:
//! at game runtime the SAME line yields a Component.ref-equivalent view
//! class (src/ruby/prelude.rb); at generate time, run through this
//! extractor, it yields the schema the assembler codegens real Zig
//! components from — byte-compatible with the lua runner's output.
//!
//! Isolation model — the one structural divergence from the lua runner:
//! lua gives every chunk a fresh stub `_ENV` inside ONE VM; ruby has no
//! chunk environments (top-level defs, constants and module mutations are
//! process-global), so this extractor opens a FRESH mrb_state PER CHUNK.
//! A chunk clobbering `Labelle.component`, defining helpers, or binding
//! constants dies with its interpreter — later files never see it. That
//! is affordable precisely because extraction is a BUILD step (an
//! mrb_open is sub-millisecond; scripts are dozens, not millions) and it
//! buys a stronger guarantee than the lua factory-stub: NOTHING survives
//! a chunk. Cross-chunk recorder state (accumulated declarations for
//! duplicate detection, emitted fragments for the final schema) lives on
//! THIS side and is threaded into each fresh state through the prelude's
//! __declare_seed/__declare_begin/__declare_take seams.
//!
//! Separate from src/ruby/vm.zig on purpose (the lua extract.zig rule):
//! vm.zig's error paths log through the Script Runtime Contract's
//! `labelle_log` extern, which only the HOST GAME binary exports — a
//! standalone tool linking vm.zig would not link. This file follows
//! vm.zig's hand-declared-extern PATTERN with its own (smaller) C-API
//! slice and no contract dependency; the mruby objects themselves come
//! from whichever module compiled them into the enclosing binary (the exe
//! root embeds them via build.zig; the test binary reuses the ones the
//! ruby-language `labelle_scripting` module already carries).
//!
//! Error policy: extraction is a BUILD step — the first malformed
//! declaration (or erroring chunk body) aborts with a file-and-line
//! bearing message (`Outcome.failure`); there is no evict-and-continue
//! like the runtime VM. A build must not half-succeed. Attribution: the
//! prelude raises from inside `Labelle.component`, so the exception's
//! backtrace carries the script's call-site frame ("<path>:<line>"); the
//! failure formatter walks the backtrace for the first frame in the
//! chunk's file (ruby's spelling of lua's error-level trick). Parser
//! errors arrive as capture_errors SyntaxErrors whose message starts
//! "line N:"; the formatter rewrites that prefix to "<path>:N:" so
//! compile failures carry their location the same way.

const std = @import("std");

/// Hand-declared mruby 3.4 C API — just the slice the extractor touches
/// (the vm.zig pattern: real MRB_API symbols plus the src/ruby/shim.c
/// flat exports for macro-shaped APIs; `mrb_state` stays opaque). The
/// `Value` mirror is ABI-valid only under the vendored build's
/// MRB_NO_BOXING + MRB_INT64 pins — see vm.zig's header note.
const c = struct {
    pub const State = opaque {};
    pub const RClass = opaque {};
    pub const Context = opaque {}; // mrbc_context, field access via shim

    pub const Int = i64; // mrb_int under MRB_INT64
    pub const Sym = u32; // mrb_sym
    pub const Bool = u8; // mrb_bool

    /// enum mrb_vtype (include/mruby/value.h) — order is ABI.
    pub const VType = enum(c_int) {
        false = 0,
        true,
        symbol,
        undef,
        free,
        float,
        integer,
        cptr,
        object,
        class,
        module,
        sclass,
        hash,
        cdata,
        exception,
        iclass,
        proc,
        array,
        string,
        range,
        env,
        fiber,
        strukt,
        istruct,
        brk,
        complex,
        rational,
        bigint,
        backtrace,
        _,
    };

    /// mrb_value under MRB_NO_BOXING (include/mruby/boxing_no.h).
    pub const Value = extern struct {
        value: extern union {
            f: f64,
            p: ?*anyopaque,
            i: Int,
            sym: Sym,
        },
        tt: VType,

        pub fn module(p: *RClass) Value {
            return .{ .value = .{ .p = p }, .tt = .module };
        }

        pub fn isNil(v: Value) bool {
            return v.tt == .false and v.value.i == 0;
        }
    };

    // State lifecycle.
    pub extern fn mrb_open() ?*State;
    pub extern fn mrb_close(mrb: ?*State) void;

    // Compile + load (mruby-compiler; mruby 3.4's real mrb_ccontext_*
    // symbols — the mrbc_* spellings are header macros).
    pub extern fn mrb_ccontext_new(mrb: ?*State) ?*Context;
    pub extern fn mrb_ccontext_free(mrb: ?*State, cxt: ?*Context) void;
    pub extern fn mrb_ccontext_filename(mrb: ?*State, cxt: ?*Context, s: [*:0]const u8) ?[*:0]const u8;
    pub extern fn mrb_load_nstring_cxt(mrb: ?*State, s: [*]const u8, len: usize, cxt: ?*Context) Value;

    // Calling + interning + values.
    pub extern fn mrb_funcall_argv(mrb: ?*State, val: Value, name: Sym, argc: Int, argv: ?[*]const Value) Value;
    pub extern fn mrb_intern(mrb: ?*State, s: [*]const u8, len: usize) Sym;
    pub extern fn mrb_define_module(mrb: ?*State, name: [*:0]const u8) ?*RClass;
    pub extern fn mrb_str_new(mrb: ?*State, p: ?[*]const u8, len: Int) Value;
    pub extern fn mrb_ary_entry(ary: Value, offset: Int) Value;
    pub extern fn mrb_obj_classname(mrb: ?*State, obj: Value) [*:0]const u8;

    // src/ruby/shim.c — macro-shaped APIs as flat functions.
    pub extern fn labelle_mrb_gc_arena_save(mrb: ?*State) c_int;
    pub extern fn labelle_mrb_gc_arena_restore(mrb: ?*State, idx: c_int) void;
    pub extern fn labelle_mrb_exc_get(mrb: ?*State) Value;
    pub extern fn labelle_mrb_exc_clear(mrb: ?*State) void;
    pub extern fn labelle_mrbc_capture_errors(cxt: ?*Context, on: Bool) void;
    pub extern fn labelle_mrb_str_ptr(s: Value) [*]const u8;
    pub extern fn labelle_mrb_str_len(s: Value) Int;
    pub extern fn labelle_mrb_ary_len(a: Value) Int;
};

const prelude_source = @embedFile("declare_prelude.rb");

/// Longest accepted script path for the mrbc filename buffer (error
/// locations and backtrace frames lose their tail beyond it — same cap
/// spirit as the lua extractor's chunkname buffer).
const CHUNKNAME_CAP = 256;

/// One script to scan: `path` names it in errors and in backtrace frames;
/// `source` is the chunk text.
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
    /// mrb_open failed (OOM inside mruby).
    RubyStateInit,
    /// The embedded declare prelude failed to load or run, or one of its
    /// seams misbehaved — an internal bug in this tool, never a
    /// user-script problem.
    DeclarePrelude,
    OutOfMemory,
};

/// One recorded declaration, accumulated across chunks: `name` + `file`
/// re-seed every later chunk's duplicate detection; `fragment` is the
/// pre-formatted schema-JSON component object the final emit joins.
const Decl = struct {
    name: []u8,
    file: []u8,
    fragment: []u8,
};

/// Borrowed view of an mruby String's bytes (valid while its state lives).
fn strSlice(v: c.Value) []const u8 {
    const len: usize = @intCast(c.labelle_mrb_str_len(v));
    return c.labelle_mrb_str_ptr(v)[0..len];
}

fn excPending(mrb: ?*c.State) bool {
    return !c.labelle_mrb_exc_get(mrb).isNil();
}

/// Run every input's chunk body through the declare stub and return the
/// schema JSON — or the first failure. See the module doc for semantics.
pub fn run(allocator: std.mem.Allocator, inputs: []const Input) Error!Outcome {
    var decls: std.ArrayList(Decl) = .empty;
    defer {
        for (decls.items) |d| {
            allocator.free(d.name);
            allocator.free(d.file);
            allocator.free(d.fragment);
        }
        decls.deinit(allocator);
    }

    for (inputs) |input| {
        if (try runChunk(allocator, input, &decls)) |failure|
            return .{ .failure = failure };
    }

    // All chunks ran clean: join the accumulated fragments. This side owns
    // the envelope so it is byte-identical to the lua __declare_emit's.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"components\":[");
    for (decls.items, 0..) |d, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, d.fragment);
    }
    try out.appendSlice(allocator, "]}");
    return .{ .schema = try out.toOwnedSlice(allocator) };
}

/// One chunk, one interpreter: open, install the prelude, seed the
/// accumulated recorder state, run the body, harvest. Returns a failure
/// message (allocator-owned) when the chunk itself misbehaved, null when
/// it ran clean (its declarations appended to `decls`).
fn runChunk(allocator: std.mem.Allocator, input: Input, decls: *std.ArrayList(Decl)) Error!?[]u8 {
    const mrb = c.mrb_open() orelse return error.RubyStateInit;
    defer c.mrb_close(mrb);

    // The declare prelude, at real top level. capture_errors so a prelude
    // typo surfaces as DeclarePrelude, not a stderr print.
    {
        const cxt = c.mrb_ccontext_new(mrb) orelse return error.DeclarePrelude;
        defer c.mrb_ccontext_free(mrb, cxt);
        _ = c.mrb_ccontext_filename(mrb, cxt, "labelle/declare_prelude.rb");
        c.labelle_mrbc_capture_errors(cxt, 1);
        _ = c.mrb_load_nstring_cxt(mrb, prelude_source.ptr, prelude_source.len, cxt);
        if (excPending(mrb)) return error.DeclarePrelude;
    }

    // Reopens the module the prelude just defined.
    const mod = c.mrb_define_module(mrb, "Labelle") orelse return error.DeclarePrelude;
    const modv = c.Value.module(mod);

    // Fresh state, fresh symbols (syms are per-state).
    const sym_seed = c.mrb_intern(mrb, "__declare_seed", "__declare_seed".len);
    const sym_begin = c.mrb_intern(mrb, "__declare_begin", "__declare_begin".len);
    const sym_take = c.mrb_intern(mrb, "__declare_take", "__declare_take".len);

    // Replay earlier files' declarations into this state's duplicate
    // detector, then stamp the current file. Arena-restored per call: the
    // seed strings are C-frame-born objects, and mruby's arena holds ~100
    // slots — an unrestored loop would overflow it on component-rich
    // projects.
    for (decls.items) |d| {
        const arena = c.labelle_mrb_gc_arena_save(mrb);
        defer c.labelle_mrb_gc_arena_restore(mrb, arena);
        const args = [_]c.Value{
            c.mrb_str_new(mrb, d.name.ptr, @intCast(d.name.len)),
            c.mrb_str_new(mrb, d.file.ptr, @intCast(d.file.len)),
        };
        _ = c.mrb_funcall_argv(mrb, modv, sym_seed, args.len, &args);
        if (excPending(mrb)) return error.DeclarePrelude;
    }
    {
        const arena = c.labelle_mrb_gc_arena_save(mrb);
        defer c.labelle_mrb_gc_arena_restore(mrb, arena);
        const args = [_]c.Value{
            c.mrb_str_new(mrb, input.path.ptr, @intCast(input.path.len)),
        };
        _ = c.mrb_funcall_argv(mrb, modv, sym_begin, args.len, &args);
        if (excPending(mrb)) return error.DeclarePrelude;
    }

    // The chunk body. The mrbc filename is the script path, so every
    // backtrace frame and SyntaxError reads against it.
    {
        var namebuf: [CHUNKNAME_CAP]u8 = undefined;
        const n = @min(input.path.len, namebuf.len - 1);
        @memcpy(namebuf[0..n], input.path[0..n]);
        namebuf[n] = 0;
        const filename: [*:0]const u8 = @ptrCast(&namebuf);

        const cxt = c.mrb_ccontext_new(mrb) orelse return error.DeclarePrelude;
        defer c.mrb_ccontext_free(mrb, cxt);
        _ = c.mrb_ccontext_filename(mrb, cxt, filename);
        c.labelle_mrbc_capture_errors(cxt, 1);
        _ = c.mrb_load_nstring_cxt(mrb, input.source.ptr, input.source.len, cxt);

        const exc = c.labelle_mrb_exc_get(mrb);
        if (!exc.isNil()) {
            c.labelle_mrb_exc_clear(mrb);
            return try formatFailure(allocator, mrb, input.path, exc);
        }
    }

    // Harvest this chunk's declarations: a flat [name, fragment, ...]
    // array, copied out before the state closes.
    {
        const arena = c.labelle_mrb_gc_arena_save(mrb);
        defer c.labelle_mrb_gc_arena_restore(mrb, arena);
        const flat = c.mrb_funcall_argv(mrb, modv, sym_take, 0, null);
        if (excPending(mrb) or flat.tt != .array) return error.DeclarePrelude;
        const len = c.labelle_mrb_ary_len(flat);
        var i: c.Int = 0;
        while (i + 1 < len) : (i += 2) {
            const nv = c.mrb_ary_entry(flat, i);
            const fv = c.mrb_ary_entry(flat, i + 1);
            if (nv.tt != .string or fv.tt != .string) return error.DeclarePrelude;
            const name = try allocator.dupe(u8, strSlice(nv));
            errdefer allocator.free(name);
            const file = try allocator.dupe(u8, input.path);
            errdefer allocator.free(file);
            const fragment = try allocator.dupe(u8, strSlice(fv));
            errdefer allocator.free(fragment);
            try decls.append(allocator, .{ .name = name, .file = file, .fragment = fragment });
        }
    }
    return null;
}

/// "line N: <rest>" (the capture_errors SyntaxError shape) → the "N: <rest>"
/// tail, or null when the message has some other shape.
fn syntaxLineTail(msg: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, msg, "line ")) return null;
    const rest = msg[5..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    if (colon == 0) return null;
    for (rest[0..colon]) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
    }
    return rest;
}

/// Format one (already TAKEN — slot cleared) exception as the failure
/// message: `labelle-declare-ruby: <path>: <path>:<line>[:in <m>]:
/// <Class>: <message>` when the backtrace carries a frame in the chunk's
/// file, the "line N:"→"<path>:N:" rewrite for parser SyntaxErrors, and a
/// class+message fallback otherwise. The formatting funcalls are guarded
/// like vm.zig's: a pathological exception degrades, never loops.
fn formatFailure(allocator: std.mem.Allocator, mrb: ?*c.State, path: []const u8, exc: c.Value) Error![]u8 {
    const arena = c.labelle_mrb_gc_arena_save(mrb);
    defer c.labelle_mrb_gc_arena_restore(mrb, arena);

    const class_name = std.mem.span(c.mrb_obj_classname(mrb, exc));

    var msg_text: []const u8 = "(message unavailable)";
    const sym_message = c.mrb_intern(mrb, "message", "message".len);
    const msg = c.mrb_funcall_argv(mrb, exc, sym_message, 0, null);
    if (excPending(mrb)) {
        c.labelle_mrb_exc_clear(mrb);
    } else if (msg.tt == .string) {
        msg_text = strSlice(msg);
    }

    // The first backtrace frame inside the chunk's file is the script's
    // own site — for a prelude-raised validation error that is the
    // Labelle.component call line (frames above it are prelude frames).
    var frame: ?[]const u8 = null;
    const sym_backtrace = c.mrb_intern(mrb, "backtrace", "backtrace".len);
    const bt = c.mrb_funcall_argv(mrb, exc, sym_backtrace, 0, null);
    if (excPending(mrb)) {
        c.labelle_mrb_exc_clear(mrb);
    } else if (bt.tt == .array) {
        const len = c.labelle_mrb_ary_len(bt);
        var i: c.Int = 0;
        while (i < len) : (i += 1) {
            const entry = c.mrb_ary_entry(bt, i);
            if (entry.tt != .string) continue;
            const s = strSlice(entry);
            if (s.len > path.len and std.mem.startsWith(u8, s, path) and s[path.len] == ':') {
                frame = s;
                break;
            }
        }
    }

    if (frame) |f| {
        return try std.fmt.allocPrint(
            allocator,
            "labelle-declare-ruby: {s}: {s}: {s}: {s}",
            .{ path, f, class_name, msg_text },
        );
    }
    if (syntaxLineTail(msg_text)) |tail| {
        // Parser errors carry no backtrace; graft their line onto the
        // path so compile failures read "<path>:<line>: ..." like
        // everything else.
        return try std.fmt.allocPrint(
            allocator,
            "labelle-declare-ruby: {s}: {s}:{s}",
            .{ path, path, tail },
        );
    }
    return try std.fmt.allocPrint(
        allocator,
        "labelle-declare-ruby: {s}: {s}: {s}",
        .{ path, class_name, msg_text },
    );
}
