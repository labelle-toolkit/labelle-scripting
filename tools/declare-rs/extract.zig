//! Rust declare-mode extraction core (labelle-declare-rs — the native-family
//! member of the cross-runner declare contract; labelle-engine#774,
//! RFC-LANGUAGE-PLUGINS rev 17 §7).
//!
//! Rust has no interpreter, so unlike the lua/ruby extractors (which load a
//! chunk body into a fresh stub VM and read back the recorded declarations —
//! tools/declare/extract.zig, tools/declare-ruby/extract.zig) this one is a
//! COMPILE-AND-RUN PROBE: it stages a tiny cargo crate under the
//! assembler-supplied cache dir, builds it, and runs it. The mechanism is the
//! assembler's blind spot by design (rev 17): to the assembler this is just an
//! exe that reads declaration files + a cache dir and prints schema JSON; that
//! it happens to shell `cargo` is internal here.
//!
//! The staged crate:
//!   <cache>/probe/Cargo.toml        — the embedded manifest template (verbatim)
//!   <cache>/probe/src/labelle.rs    — the SHIPPED native/src/labelle.rs (embedded
//!                                     at build time, so the probe carries the
//!                                     exact macros/emitter the tool was built
//!                                     against)
//!   <cache>/probe/src/main.rs       — generated: `#[path="labelle.rs"] pub mod
//!                                     labelle;`, one `#[path="decl_NNNN.rs"] mod
//!                                     decl_NNNN;` per input, and a main that
//!                                     prints `labelle::emit_schema()`
//!   <cache>/probe/src/decl_NNNN.rs  — the INJECTED PRELUDE + one declaration
//!                                     file VERBATIM (NNNN = zero-padded argv
//!                                     index)
//!
//! Ordering: emit_schema sorts each kind by (file!(), line!()). The staged
//! module names are `decl_NNNN` where NNNN is the zero-padded ARGV INDEX, so
//! the file-path sort reproduces argv order — and the assembler passes
//! components/*.rs before events/*.rs, so components-then-events falls out for
//! free (each kind keeps its own array; cross-kind interleaving in one input is
//! irrelevant, emit_schema splits by kind first).
//!
//! The injected prelude — the ONE subtlety. A real game `components/*.rs`
//! writes bare `labelle::component!{…}` and bare `vec2(…)` with NO `use` lines
//! (the shipped labelle.rs re-exports the macros AND the vec2 ctor into the
//! `labelle` module path — native/src/labelle.rs). So each staged module is
//! prepended with exactly the two `use` lines a game omits, bringing the
//! `labelle` module and the `vec2` ctor into scope; the game file then compiles
//! verbatim. The `line!()` shift the prelude introduces is uniform within a
//! file, so per-file declaration order is preserved.
//!
//! Error policy: extraction is a BUILD step — a cargo build failure aborts with
//! the compiler's stderr (`Outcome.failure`); there is no half-success. Rust's
//! own diagnostics carry the `decl_NNNN.rs:line` location (the staged file),
//! which is the game file's content — good enough to point the developer at the
//! offending declaration.

const std = @import("std");

/// The SHIPPED labelle module + the probe manifest template, embedded at build
/// time (build.zig anonymous imports) so the tool is self-contained and carries
/// the exact macro/emitter surface it was built against.
const labelle_rs_source = @embedFile("labelle_rs_src");
const cargo_toml_source = @embedFile("probe_cargo_toml");

/// The `use` lines a game-shaped declaration file omits (the shipped labelle.rs
/// re-exports `component!`/`event!` and the `vec2` ctor into the `labelle`
/// module path). Prepended to every staged declaration module so bare
/// `labelle::component!{…}` / `vec2(…)` resolve — pinned by
/// tests/declare_rust_tool.zig's fixtures (game-shaped, no `use` lines).
const injected_prelude = "use crate::labelle;\nuse crate::labelle::vec2;\n";

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
    /// Staging the probe crate under the cache dir failed (mkdir/write) — an
    /// environment problem (bad cache dir, disk), never a user-script problem.
    ProbeStage,
    /// cargo could not be spawned, or its stdout/stderr could not be read —
    /// a toolchain/environment problem (cargo missing from PATH, pipe error).
    ProbeSpawn,
    OutOfMemory,
};

/// Stage the probe crate under `cache_dir`, cargo-build it (`--features
/// declare`, debug — the warm rebuild the persistent `--target-dir` buys), run
/// the built probe, and return its schema JSON — or the first failure. See the
/// module doc for the staging layout and ordering contract.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_dir: []const u8,
    inputs: []const Input,
) Error!Outcome {
    const cwd = std.Io.Dir.cwd();

    const probe_dir = std.fs.path.join(allocator, &.{ cache_dir, "probe" }) catch return error.OutOfMemory;
    defer allocator.free(probe_dir);
    const src_dir = std.fs.path.join(allocator, &.{ probe_dir, "src" }) catch return error.OutOfMemory;
    defer allocator.free(src_dir);

    cwd.createDirPath(io, src_dir) catch return error.ProbeStage;

    // Cargo.toml + the shipped labelle module (both embedded verbatim).
    writeUnder(cwd, io, allocator, probe_dir, "Cargo.toml", cargo_toml_source) catch return error.ProbeStage;
    writeUnder(cwd, io, allocator, src_dir, "labelle.rs", labelle_rs_source) catch return error.ProbeStage;

    // One staged module per input (prelude + game file verbatim) + the
    // generated main that includes them and prints the schema.
    var main_rs: std.ArrayList(u8) = .empty;
    defer main_rs.deinit(allocator);
    try main_rs.appendSlice(allocator,
        \\// Generated by labelle-declare-rs (labelle-engine#774). Do not edit.
        \\#![allow(dead_code, unused_imports)]
        \\
        \\#[path = "labelle.rs"]
        \\pub mod labelle;
        \\
        \\
    );
    for (inputs, 0..) |input, i| {
        var namebuf: [32]u8 = undefined;
        const mod_name = std.fmt.bufPrint(&namebuf, "decl_{d:0>4}", .{i}) catch return error.OutOfMemory;

        const file_name = std.fmt.allocPrint(allocator, "{s}.rs", .{mod_name}) catch return error.OutOfMemory;
        defer allocator.free(file_name);
        const staged = std.fmt.allocPrint(allocator, "{s}{s}", .{ injected_prelude, input.source }) catch return error.OutOfMemory;
        defer allocator.free(staged);
        writeUnder(cwd, io, allocator, src_dir, file_name, staged) catch return error.ProbeStage;

        main_rs.appendSlice(allocator, "#[path = \"") catch return error.OutOfMemory;
        try main_rs.appendSlice(allocator, file_name);
        try main_rs.appendSlice(allocator, "\"]\nmod ");
        try main_rs.appendSlice(allocator, mod_name);
        try main_rs.appendSlice(allocator, ";\n");
    }
    try main_rs.appendSlice(allocator,
        \\
        \\fn main() {
        \\    println!("{}", labelle::emit_schema());
        \\}
        \\
    );
    writeUnder(cwd, io, allocator, src_dir, "main.rs", main_rs.items) catch return error.ProbeStage;

    // Build the probe. Debug (the warm ~0.4s rebuild the persistent target-dir
    // buys); `--features declare` turns on the macro schema registration +
    // emit_schema's inventory dep. Env inherited (RUSTUP_HOME/CARGO_HOME).
    const manifest_path = std.fs.path.join(allocator, &.{ probe_dir, "Cargo.toml" }) catch return error.OutOfMemory;
    defer allocator.free(manifest_path);
    const build_argv = [_][]const u8{
        "cargo",         "build",
        "--features",    "declare",
        "--manifest-path", manifest_path,
        "--target-dir",  cache_dir,
    };
    const build_res = std.process.run(allocator, io, .{ .argv = &build_argv }) catch return error.ProbeSpawn;
    defer allocator.free(build_res.stdout);
    defer allocator.free(build_res.stderr);
    if (build_res.term != .exited or build_res.term.exited != 0) {
        // Surface cargo/rustc's own diagnostics — they carry the staged
        // decl_NNNN.rs:line location (the game file's content).
        const msg = std.fmt.allocPrint(
            allocator,
            "labelle-declare-rs: cargo build failed:\n{s}",
            .{build_res.stderr},
        ) catch return error.OutOfMemory;
        return .{ .failure = msg };
    }

    // Run the built probe; its stdout is the schema JSON (+ println's newline).
    const exe_name = "labelle-declare-probe" ++ if (@import("builtin").os.tag == .windows) ".exe" else "";
    const probe_bin = std.fs.path.join(allocator, &.{ cache_dir, "debug", exe_name }) catch return error.OutOfMemory;
    defer allocator.free(probe_bin);
    const run_res = std.process.run(allocator, io, .{ .argv = &.{probe_bin} }) catch return error.ProbeSpawn;
    defer allocator.free(run_res.stdout);
    defer allocator.free(run_res.stderr);
    if (run_res.term != .exited or run_res.term.exited != 0) {
        const msg = std.fmt.allocPrint(
            allocator,
            "labelle-declare-rs: probe run failed:\n{s}",
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
