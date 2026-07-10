//! labelle-scripting build: the shared plugin glue plus exactly ONE
//! language sub-module, selected at build time.
//!
//! Language selection is a build option (`-Dlanguage=lua`) rather than
//! N sibling packages because every language binds the same Script
//! Runtime Contract and exposes the same Controller — one module name
//! (`labelle_scripting`), one plugin entry in project.labelle, N
//! interchangeable VMs behind it. Unchosen languages must cost nothing:
//! each vendored runtime is a `.lazy = true` dependency resolved through
//! `b.lazyDependency`, so it is only downloaded when its language is the
//! selected one — a lua game never fetches QuickJS and vice versa.

const std = @import("std");

/// The language sub-modules this plugin can embed. One per game — the
/// choice is a whole-VM decision, so it lives in the build graph, not at
/// runtime. Adding a language is additive: extend this enum, gate its
/// vendored runtime in the switch below, add `src/<lang>/` and its arm
/// in src/root.zig's backend switch. Nothing existing changes.
const Language = enum { lua };

/// Lua 5.4.8 sources, minus the `lua.c`/`luac.c` executable mains
/// (interpreter core + auxlib + all standard libraries).
const lua_sources = [_][]const u8{
    "lapi.c",     "lauxlib.c",  "lbaselib.c", "lcode.c",
    "lcorolib.c", "lctype.c",   "ldblib.c",   "ldebug.c",
    "ldo.c",      "ldump.c",    "lfunc.c",    "lgc.c",
    "linit.c",    "liolib.c",   "llex.c",     "lmathlib.c",
    "lmem.c",     "loadlib.c",  "lobject.c",  "lopcodes.c",
    "loslib.c",   "lparser.c",  "lstate.c",   "lstring.c",
    "lstrlib.c",  "ltable.c",   "ltablib.c",  "ltm.c",
    "lundump.c",  "lutf8lib.c", "lvm.c",      "lzio.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const language = b.option(
        Language,
        "language",
        "Scripting language sub-module to embed (default: lua)",
    ) orelse .lua;

    // Surface the choice to src/root.zig so the backend dispatch is a
    // comptime switch — the unselected backends are never analyzed, which
    // is what keeps their extern VM symbols out of the link.
    const opts = b.addOptions();
    opts.addOption(Language, "language", language);

    // The plugin module. The assembler requests plugin modules by the
    // convention name `labelle_<pluginname>`; plugin.labelle says
    // `.name = "scripting"`, so `labelle_scripting` is both the package
    // module name and the assembler-facing name — no aliasing needed
    // (unlike labelle-pathfinding, where the two spellings differ).
    //
    // link_libc is module-level (Zig 0.16): the embedded VMs are C.
    const scripting_mod = b.addModule("labelle_scripting", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    scripting_mod.addOptions("scripting_options", opts);

    switch (language) {
        .lua => if (b.lazyDependency("lua", .{})) |lua_dep| {
            // Vendored Lua 5.4, compiled straight into the module: every
            // .c in the official release tarball except the two standalone
            // mains (lua.c interpreter, luac.c compiler). The explicit list
            // — not onelua.c, which only exists in the GitHub mirror, not
            // in lua.org release tarballs — matches upstream's own liblua
            // Makefile (CORE_O + LIB_O + AUX_O). No platform defines on
            // purpose: the generic ANSI build works on every labelle
            // target, and the dynamic-loading extras they gate (dlopen for
            // `require` of C modules) are meaningless here — scripts arrive
            // through registerScript, never from disk.
            scripting_mod.addIncludePath(lua_dep.path("src"));
            scripting_mod.addCSourceFiles(.{
                .root = lua_dep.path("src"),
                .files = &lua_sources,
            });
        },
    }

    // Tests: the contract symbols are `extern` in src/contract.zig and the
    // test root provides them (tests/mock_world.zig `export`s a toy world),
    // mirroring production exactly — there the assembled game binary is the
    // exporter. Same-binary resolution either way, so no libs to link.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "labelle_scripting", .module = scripting_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests against the mock host world");
    test_step.dependOn(&run_tests.step);
}
