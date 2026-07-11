//! labelle-scripting build: the shared plugin glue plus exactly ONE
//! language sub-module, selected at build time.
//!
//! Language selection is a build option (`-Dlanguage=lua|ruby`) rather
//! than N sibling packages because every language binds the same Script
//! Runtime Contract and exposes the same Controller — one module name
//! (`labelle_scripting`), one plugin entry in project.labelle, N
//! interchangeable VMs behind it. Unchosen languages must cost nothing:
//! lua's vendored runtime is a `.lazy = true` dependency resolved through
//! `b.lazyDependency` (never even downloaded unless selected), while
//! ruby's vendored mruby output lives in-repo under vendor/mruby/ and is
//! only COMPILED when selected — fetch-laziness is lost there (mruby has
//! no amalgamation and its upstream build needs host ruby+rake, which
//! consumers must never need; see vendor/mruby's provenance note in the
//! README), build-laziness is kept.

const std = @import("std");

/// The language sub-modules this plugin can embed. One per game — the
/// choice is a whole-VM decision, so it lives in the build graph, not at
/// runtime. Adding a language is additive: extend this enum, gate its
/// vendored runtime in the switch below, add `src/<lang>/` and its arm
/// in src/root.zig's backend switch. Nothing existing changes.
const Language = enum { lua, ruby };

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

/// mruby 3.4.0, vendored as the upstream sources PLUS the C files its
/// rake build generates (core mrblib bytecode, per-gem init bytecode,
/// presym tables under include/mruby/presym/) — the one-time-build output
/// snapshot that spares consumers the host ruby+rake requirement.
/// Regenerate with vendor/mruby/README.md's recipe when bumping mruby.
const mruby_sources = [_][]const u8{
    // core VM (src/mrblib.c is the generated core-library bytecode)
    "src/allocf.c",
    "src/array.c",
    "src/backtrace.c",
    "src/cdump.c",
    "src/class.c",
    "src/codedump.c",
    "src/debug.c",
    "src/dump.c",
    "src/enum.c",
    "src/error.c",
    "src/etc.c",
    "src/fmt_fp.c",
    "src/gc.c",
    "src/hash.c",
    "src/init.c",
    "src/kernel.c",
    "src/load.c",
    "src/mempool.c",
    "src/mrblib.c",
    "src/numeric.c",
    "src/numops.c",
    "src/object.c",
    "src/print.c",
    "src/proc.c",
    "src/range.c",
    "src/readfloat.c",
    "src/readint.c",
    "src/readnum.c",
    "src/state.c",
    "src/string.c",
    "src/symbol.c",
    "src/variable.c",
    "src/version.c",
    "src/vm.c",
    // compiler gem (runtime script loading; y.tab.c is the pre-generated
    // parser shipped in mruby release trees)
    "mrbgems/mruby-compiler/core/codegen.c",
    "mrbgems/mruby-compiler/core/y.tab.c",
    // gem registry + per-gem inits (generated) and gem C extensions
    "mrbgems/gem_init.c",
    "mrbgems/mruby-array-ext/gem_init.c",
    "mrbgems/mruby-array-ext/src/array.c",
    "mrbgems/mruby-catch/gem_init.c",
    "mrbgems/mruby-catch/src/catch.c",
    "mrbgems/mruby-class-ext/gem_init.c",
    "mrbgems/mruby-class-ext/src/class.c",
    "mrbgems/mruby-compar-ext/gem_init.c",
    "mrbgems/mruby-enum-ext/gem_init.c",
    "mrbgems/mruby-enum-lazy/gem_init.c",
    "mrbgems/mruby-enumerator/gem_init.c",
    "mrbgems/mruby-error/gem_init.c",
    "mrbgems/mruby-error/src/exception.c",
    "mrbgems/mruby-fiber/gem_init.c",
    "mrbgems/mruby-fiber/src/fiber.c",
    "mrbgems/mruby-hash-ext/gem_init.c",
    "mrbgems/mruby-hash-ext/src/hash-ext.c",
    "mrbgems/mruby-kernel-ext/gem_init.c",
    "mrbgems/mruby-kernel-ext/src/kernel.c",
    "mrbgems/mruby-math/gem_init.c",
    "mrbgems/mruby-math/src/math.c",
    "mrbgems/mruby-metaprog/gem_init.c",
    "mrbgems/mruby-metaprog/src/metaprog.c",
    "mrbgems/mruby-numeric-ext/gem_init.c",
    "mrbgems/mruby-numeric-ext/src/numeric_ext.c",
    "mrbgems/mruby-object-ext/gem_init.c",
    "mrbgems/mruby-object-ext/src/object.c",
    "mrbgems/mruby-objectspace/gem_init.c",
    "mrbgems/mruby-objectspace/src/mruby_objectspace.c",
    "mrbgems/mruby-proc-ext/gem_init.c",
    "mrbgems/mruby-proc-ext/src/proc.c",
    "mrbgems/mruby-random/gem_init.c",
    "mrbgems/mruby-random/src/random.c",
    "mrbgems/mruby-range-ext/gem_init.c",
    "mrbgems/mruby-range-ext/src/range.c",
    "mrbgems/mruby-set/gem_init.c",
    "mrbgems/mruby-sprintf/gem_init.c",
    "mrbgems/mruby-sprintf/src/sprintf.c",
    "mrbgems/mruby-string-ext/gem_init.c",
    "mrbgems/mruby-string-ext/src/string.c",
    "mrbgems/mruby-struct/gem_init.c",
    "mrbgems/mruby-struct/src/struct.c",
    "mrbgems/mruby-symbol-ext/gem_init.c",
    "mrbgems/mruby-symbol-ext/src/symbol.c",
    "mrbgems/mruby-toplevel-ext/gem_init.c",
};

/// Defines the vendored mruby MUST be compiled with — they are baked into
/// the generated presym/bytecode snapshot's build config (see
/// labelle_mruby_config.rb in vendor/mruby/README.md) and into the Zig
/// bindings' hand-mirrored mrb_value ABI:
///   MRB_INT64      — entity ids ride mrb_int as the signed 64-bit bitcast;
///   MRB_NO_BOXING  — mrb_value as the mirrorable {union, tag} struct
///                    (word boxing, mruby's default, is not hand-declarable
///                    and demotes bit-63 integers to heap allocations).
const mruby_defines = [_][]const u8{ "-DMRB_INT64", "-DMRB_NO_BOXING" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const language = b.option(
        Language,
        "language",
        "Scripting language sub-module to embed (default: lua)",
    ) orelse .lua;

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
    configureLanguage(b, scripting_mod, language);

    // Tests: the contract symbols are `extern` in src/contract.zig and the
    // test root provides them (tests/mock_world.zig `export`s a toy world),
    // mirroring production exactly — there the assembled game binary is the
    // exporter. Same-binary resolution either way, so no libs to link.
    //
    // `zig build test` runs EVERY language's suite — one test binary per
    // enum value, each with its own module instance — so a change to the
    // shared glue cannot silently break the languages it wasn't built
    // against. (The exported module above stays single-language; only the
    // repo's own tests pay for building all VMs.)
    const test_step = b.step("test", "Run all language suites against the mock host world");
    inline for (@typeInfo(Language).@"enum".fields) |field| {
        const lang: Language = @enumFromInt(field.value);
        const lang_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        configureLanguage(b, lang_mod, lang);
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/root.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "labelle_scripting", .module = lang_mod },
                },
            }),
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}

/// Wire `mod` for one language: the `scripting_options` module feeding
/// src/root.zig's comptime backend switch, plus the language's vendored
/// runtime sources. Unselected runtimes are neither fetched (lua, lazy
/// dependency) nor compiled (ruby, in-repo vendor).
fn configureLanguage(b: *std.Build, mod: *std.Build.Module, language: Language) void {
    const opts = b.addOptions();
    opts.addOption(Language, "language", language);
    mod.addOptions("scripting_options", opts);

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
            mod.addIncludePath(lua_dep.path("src"));
            mod.addCSourceFiles(.{
                .root = lua_dep.path("src"),
                .files = &lua_sources,
            });
        },
        .ruby => {
            // Vendored mruby 3.4 (see mruby_sources) plus src/ruby/shim.c,
            // our thin C exports for the APIs that are macros over
            // mrb_state internals — compiled together so every macro
            // expands against the same headers and defines.
            mod.addIncludePath(b.path("vendor/mruby/include"));
            mod.addCSourceFiles(.{
                .root = b.path("vendor/mruby"),
                .files = &mruby_sources,
                .flags = &mruby_defines,
            });
            mod.addCSourceFile(.{
                .file = b.path("src/ruby/shim.c"),
                .flags = &mruby_defines,
            });
        },
    }
}
