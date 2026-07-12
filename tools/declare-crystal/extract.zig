//! Crystal declare-mode extraction core (labelle-declare-crystal — the
//! native-family member of the cross-runner declare contract, rust's twin;
//! labelle-engine#775, RFC-LANGUAGE-PLUGINS §4).
//!
//! Crystal has no interpreter, so — like tools/declare-rs/extract.zig and
//! unlike the lua/ruby extractors (which load a chunk body into a fresh stub VM
//! and read back the recorded declarations) — this one is a COMPILE-AND-RUN
//! PROBE: it stages a tiny crystal program under the assembler-supplied cache
//! dir, `crystal build`s it, and runs it. The mechanism is the assembler's
//! blind spot by design (rev 17): to the assembler this is just an exe that
//! reads declaration files + a cache dir and prints schema JSON; that it
//! happens to shell `crystal` is internal here.
//!
//! The staged program:
//!   <cache>/probe/labelle.cr     — the SHIPPED native-crystal/src/labelle.cr
//!                                  (embedded at build time, so the probe
//!                                  carries the exact macros/emitter the tool
//!                                  was built against)
//!   <cache>/probe/decl_NNNN.cr   — the INJECTED PRELUDE + one declaration file
//!                                  VERBATIM (NNNN = zero-padded argv index)
//!   <cache>/probe/main.cr        — generated: `require "./decl_NNNN"` per
//!                                  input (argv order) + `puts
//!                                  Labelle.emit_schema`
//!
//! Ordering: crystal runs each required file's top-level code in require order,
//! and `main.cr` requires the inputs in ARGV order (decl_0000 before
//! decl_0001), so each `Labelle.component`/`event` call registers in argv order
//! — and the assembler passes components/*.cr before events/*.cr, so
//! components-then-events falls out for free (emit_schema keeps a separate
//! insertion-ordered array per kind). This is why — unlike the rust probe,
//! which sorts declarations on (file, line) because inventory's collection
//! order is unspecified — the crystal probe needs no position sort.
//!
//! The injected prelude — the ONE subtlety. A real game `components/*.cr`
//! writes bare `Labelle.component "…"` with NO `require` line (a game would
//! never `require "./labelle"` — the assembler/tool stages that). So each
//! staged module is prepended with exactly the one `require` line a game omits,
//! bringing the shipped `Labelle` module (macros + emitter) into scope; the
//! game file then compiles verbatim. crystal `require` is idempotent, so every
//! decl module requiring it is fine. tests/declare_crystal_tool.zig's fixtures
//! are game-shaped (no `require` line) so a green run proves the injection.
//!
//! Error policy: extraction is a BUILD step — a crystal build failure aborts
//! with the compiler's stderr (`Outcome.failure`); there is no half-success.
//! Crystal's own diagnostics carry the `decl_NNNN.cr:line` location (the staged
//! file), which is the game file's content (shifted by the one-line prelude) —
//! good enough to point the developer at the offending declaration.

const std = @import("std");

/// The SHIPPED Labelle module, embedded at build time (build.zig anonymous
/// import) so the tool is self-contained and carries the exact macro/emitter
/// surface it was built against.
const labelle_cr_source = @embedFile("labelle_cr_src");

/// The `require` line a game-shaped declaration file omits. Prepended to every
/// staged declaration module so bare `Labelle.component`/`event` resolve —
/// pinned by tests/declare_crystal_tool.zig's fixtures (game-shaped, NO
/// `require` lines).
const injected_prelude = "require \"./labelle\"\n";

/// One declaration file to extract: `path` names it in usage/read errors;
/// `source` is its full text, staged verbatim after the injected prelude.
pub const Input = struct {
    path: []const u8,
    source: []const u8,
};

/// Either the schema JSON (one compact line, no trailing newline) or the first
/// failure, as a printable message. The active slice is owned by the caller
/// (allocated with the `run` allocator).
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
    /// Staging the probe program under the cache dir failed (mkdir/write) — an
    /// environment problem (bad cache dir, disk), never a user-script problem.
    ProbeStage,
    /// crystal could not be spawned, or its stdout/stderr could not be read —
    /// a toolchain/environment problem (crystal missing from PATH, pipe error).
    ProbeSpawn,
    OutOfMemory,
};

/// Stage the probe program under `cache_dir`, `crystal build -Ddeclare` it
/// (debug — no `--release`; whole-program compile is slow enough without the
/// LLVM opt pass, and the persistent `CRYSTAL_CACHE_DIR` buys the warm rebuild),
/// run the built probe, and return its schema JSON — or the first failure. See
/// the module doc for the staging layout and ordering contract.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    cache_dir: []const u8,
    inputs: []const Input,
) Error!Outcome {
    const cwd = std.Io.Dir.cwd();

    const probe_dir = std.fs.path.join(allocator, &.{ cache_dir, "probe" }) catch return error.OutOfMemory;
    defer allocator.free(probe_dir);

    cwd.createDirPath(io, probe_dir) catch return error.ProbeStage;

    // The shipped Labelle module (embedded verbatim).
    writeUnder(cwd, io, allocator, probe_dir, "labelle.cr", labelle_cr_source) catch return error.ProbeStage;

    // One staged module per input (prelude + game file verbatim) + the
    // generated main that requires them (argv order) and prints the schema.
    var main_cr: std.ArrayList(u8) = .empty;
    defer main_cr.deinit(allocator);
    try main_cr.appendSlice(allocator,
        \\# Generated by labelle-declare-crystal (labelle-engine#775). Do not edit.
        \\
    );
    for (inputs, 0..) |input, i| {
        var namebuf: [32]u8 = undefined;
        const mod_name = std.fmt.bufPrint(&namebuf, "decl_{d:0>4}", .{i}) catch return error.OutOfMemory;

        const file_name = std.fmt.allocPrint(allocator, "{s}.cr", .{mod_name}) catch return error.OutOfMemory;
        defer allocator.free(file_name);
        const staged = std.fmt.allocPrint(allocator, "{s}{s}", .{ injected_prelude, input.source }) catch return error.OutOfMemory;
        defer allocator.free(staged);
        writeUnder(cwd, io, allocator, probe_dir, file_name, staged) catch return error.ProbeStage;

        try main_cr.appendSlice(allocator, "require \"./");
        try main_cr.appendSlice(allocator, mod_name);
        try main_cr.appendSlice(allocator, "\"\n");
    }
    try main_cr.appendSlice(allocator,
        \\puts Labelle.emit_schema
        \\
    );
    writeUnder(cwd, io, allocator, probe_dir, "main.cr", main_cr.items) catch return error.ProbeStage;

    // Warm the persistent compile cache: crystal reads CRYSTAL_CACHE_DIR from
    // the environment (there is no flag), so point it inside the cache dir the
    // assembler handed us. `environ_map` already carries the parent env
    // (PATH, CRYSTAL_PATH, CRYSTAL_LIBRARY_PATH, …) — we add the one key and
    // pass the whole map as the child environment.
    const crystal_cache = std.fs.path.join(allocator, &.{ cache_dir, "crystal-cache" }) catch return error.OutOfMemory;
    defer allocator.free(crystal_cache);
    cwd.createDirPath(io, crystal_cache) catch return error.ProbeStage;
    environ_map.put("CRYSTAL_CACHE_DIR", crystal_cache) catch return error.OutOfMemory;

    // Build the probe. `-Ddeclare` turns on the macro schema registration +
    // the emitter (labelle.cr's `{% if flag?(:declare) %}` machinery); a normal
    // build would expand the macros to nothing.
    const main_path = std.fs.path.join(allocator, &.{ probe_dir, "main.cr" }) catch return error.OutOfMemory;
    defer allocator.free(main_path);
    const exe_name = "labelle-declare-crystal-probe" ++ if (@import("builtin").os.tag == .windows) ".exe" else "";
    const probe_bin = std.fs.path.join(allocator, &.{ cache_dir, exe_name }) catch return error.OutOfMemory;
    defer allocator.free(probe_bin);
    const build_argv = [_][]const u8{
        "crystal", "build",
        "-Ddeclare",
        main_path,
        "-o",      probe_bin,
    };
    const build_res = std.process.run(allocator, io, .{
        .argv = &build_argv,
        .environ_map = environ_map,
    }) catch return error.ProbeSpawn;
    defer allocator.free(build_res.stdout);
    defer allocator.free(build_res.stderr);
    if (build_res.term != .exited or build_res.term.exited != 0) {
        // Surface crystal's own diagnostics — they carry the staged
        // decl_NNNN.cr:line location (the game file's content).
        const msg = std.fmt.allocPrint(
            allocator,
            "labelle-declare-crystal: crystal build failed:\n{s}",
            .{build_res.stderr},
        ) catch return error.OutOfMemory;
        return .{ .failure = msg };
    }

    // Run the built probe; its stdout is the schema JSON (+ puts's newline).
    const run_res = std.process.run(allocator, io, .{
        .argv = &.{probe_bin},
        .environ_map = environ_map,
    }) catch return error.ProbeSpawn;
    defer allocator.free(run_res.stdout);
    defer allocator.free(run_res.stderr);
    if (run_res.term != .exited or run_res.term.exited != 0) {
        const msg = std.fmt.allocPrint(
            allocator,
            "labelle-declare-crystal: probe run failed:\n{s}",
            .{run_res.stderr},
        ) catch return error.OutOfMemory;
        return .{ .failure = msg };
    }

    // Trim the probe's trailing newline; main.zig re-adds one (the
    // labelle-declare contract: schema, one line, then a newline).
    const trimmed = std.mem.trimEnd(u8, run_res.stdout, "\r\n");
    return .{ .schema = try allocator.dupe(u8, trimmed) };
}

/// Write `data` to `<dir>/<name>`, joining the path with the run allocator.
fn writeUnder(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    parent: []const u8,
    name: []const u8,
    data: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ parent, name });
    defer allocator.free(path);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}
