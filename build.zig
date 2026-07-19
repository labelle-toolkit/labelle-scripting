//! labelle-scripting build: the shared plugin glue plus exactly ONE
//! language sub-module, selected at build time.
//!
//! Language selection is a build option (`-Dlanguage=lua|ruby|typescript|
//! rust|crystal|csharp`) rather than N sibling packages because every
//! language binds the same
//! Script Runtime Contract and exposes the same Controller — one module
//! name (`labelle_scripting`), one plugin entry in project.labelle, N
//! interchangeable VMs behind it. Unchosen languages must not be
//! COMPILED: lua's and typescript's vendored runtimes ride `.lazy = true`
//! dependencies, ruby's vendored mruby output lives in-repo under
//! vendor/mruby/ (mruby has no amalgamation and its upstream build needs
//! host ruby+rake, which consumers must never need; see vendor/mruby's
//! provenance note in the README). Lua IS always fetched, whatever the
//! language: the declare-mode extractor (tools/declare, `zig build
//! labelle-declare`, labelle-assembler#585) is itself lua-based and ships
//! with every install of the plugin. Declare runners are PER-LANGUAGE
//! siblings — tools/declare-ruby (`zig build labelle-declare-ruby`) is
//! the mruby one; the assembler selects the step by the project's script
//! language.

const std = @import("std");

/// `crystal env CRYSTAL_LIBRARY_PATH` splitting (colon-separated) —
/// shared with the test suite as the `crystal_lib_paths` named module.
const crystal_lib_paths = @import("tools/crystal_lib_paths.zig");

/// The language sub-modules this plugin can embed. One per game — the
/// choice is a whole-VM decision, so it lives in the build graph, not at
/// runtime. Adding a language is additive: extend this enum, gate its
/// vendored runtime in the switch below, add `src/<lang>/` and its arm
/// in src/root.zig's backend switch. Nothing existing changes.
///
/// `rust` is the first NATIVE-COMPILED entry (labelle-engine#741): no
/// vendored runtime — game scripts compile via cargo into a staticlib
/// (native/ is the crate; the assembler's declared build step runs
/// cargo in consumer games, this build.zig's test wiring runs it for
/// the repo's own suite) and the selected sub-module is a thin
/// dispatcher onto the crate's exported entry points.
///
/// `crystal` is the second native entry, on rust's exact skeleton with
/// one extra build step: crystal has no `--no-main`, so the object
/// `crystal build --cross-compile` emits still carries a `main` that
/// would collide with the game's — a localization pass (`ld -r
/// -exported_symbols_list` on macOS, `objcopy --keep-global-symbols`
/// on linux) demotes every symbol but the labelle_cr_* entries before
/// the object links in (the labelle-engine#734 POC's recipe).
///
/// `csharp` is the epic's FINAL entry (labelle-engine#743): a CoreCLR
/// HOST. Nothing is vendored or compiled into the Zig module — game
/// scripts compile to a managed assembly (`labelle_csharp_scripts.dll`,
/// via `dotnet build`) that src/csharp/vm.zig LOADS at runtime through the
/// .NET hosting API (hostfxr). Desktop-first: mobile AOT is out of v1
/// (labelle-engine#743). The declared build step is a `dotnet` publish,
/// not a link — the assembly rides beside the game binary, not inside it.
const Language = enum { lua, ruby, typescript, rust, crystal, csharp };

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
///   MRB_NO_DEFAULT_RO_DATA_P — on Linux mrbconf.h defaults to the
///                    etext/edata read-only-data probe, but zig's lld does
///                    not synthesize those legacy libc symbols, so the link
///                    fails (undefined: etext/edata). Opting out (the
///                    mrbconf.h-documented knob) merely makes mruby COPY
///                    C string literals instead of aliasing them.
const mruby_defines = [_][]const u8{ "-DMRB_INT64", "-DMRB_NO_BOXING", "-DMRB_NO_DEFAULT_RO_DATA_P" };

/// quickjs-ng v0.15.1 library sources — the exact `qjs_sources` list from
/// upstream's CMakeLists.txt (quickjs-libc.c deliberately excluded: it is
/// the os/std module layer for the qjs CLI; game scripts get the labelle
/// API instead, and scripts arrive through registerScript, never disk).
const quickjs_sources = [_][]const u8{
    "dtoa.c",
    "libregexp.c",
    "libunicode.c",
    "quickjs.c",
};

/// Flags the vendored quickjs-ng MUST be compiled with:
///   -D_GNU_SOURCE      — upstream compiles with it unconditionally
///                        (CMakeLists `qjs_defines`); harmless off-Linux.
///   -DJS_NAN_BOXING=0  — pin JSValue to the {union, i64 tag} struct
///                        encoding on EVERY target. The header would flip
///                        32-bit targets (wasm32) to NaN-boxed u64 values,
///                        which the Zig bindings' hand-mirrored `c.Value`
///                        ABI could not follow. The struct encoding is the
///                        primary, always-tested representation upstream;
///                        pinning it costs 32-bit targets a fatter value
///                        and buys one mirror that is correct everywhere.
///   -funsigned-char    — upstream compiles with it (CMakeLists
///                        `xcheck_add_c_compiler_flag`); char signedness
///                        is ABI-adjacent in the lexer tables, so match.
const quickjs_flags = [_][]const u8{ "-D_GNU_SOURCE", "-DJS_NAN_BOXING=0", "-funsigned-char" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const language = b.option(
        Language,
        "language",
        "Scripting language sub-module to embed (default: lua)",
    ) orelse .lua;

    // The vendored Lua 5.4 sources serve TWO consumers: the lua language
    // sub-module (when selected) and the declare-mode extractor below
    // (ALWAYS — it IS the lua declare runner, whatever language the game
    // scripts in). So the lazy fetch lives here, not under the language
    // gate: lua is fetched for every install; unselected it merely isn't
    // COMPILED into the plugin module.
    const lua_dep_opt = b.lazyDependency("lua", .{});

    // quickjs (the typescript sub-module's VM) is only COMPILED when
    // selected, but the fetch marking happens whenever configureLanguage's
    // .typescript arm runs — which the all-languages test loop below does
    // on every configure. In a consumer game only its chosen language's
    // module is built; the fetch is the whole cost of the others.
    const quickjs_dep_opt = b.lazyDependency("quickjs", .{});

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
    configureLanguage(b, scripting_mod, language, lua_dep_opt, quickjs_dep_opt);

    // The engine STUB behind src/contract.zig's `host_has_bulk_access`
    // comptime probe (contract v1.3, #41). Generated games get the REAL
    // labelle-engine module from the assembler's plugin wiring — the
    // generated build.zig's `overrideImport(plugin_scripting_mod,
    // "labelle-engine", engine_mod)` unconditionally installs it (getOrPut:
    // replaces an existing entry, ADDS a missing one) — so the stub is
    // wired into the in-repo TEST modules ONLY, never the exported
    // `labelle_scripting` module above: a consumer that somehow bypassed
    // the assembler wiring fails LOUDLY ("no module named
    // 'labelle-engine'") instead of silently compiling bulk-capable
    // against a host that may not export the symbols. In tests the stub's
    // v1.3 marker answers the probe TRUE, matching the mock world (which
    // exports the four bulk-access symbols). See the stub's doc.
    const engine_stub_mod = b.createModule(.{
        .root_source_file = b.path("src/engine_stub.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The extractor CORE as a named module for the tests below: tests/ is
    // its own module root, so tools/declare/extract.zig can't be reached by
    // path import from there (cross-root path imports don't resolve) — the
    // named module is the standard promotion. No C sources attached HERE on
    // purpose: within the lua test binary the lua objects already come from
    // the language module (extract.zig only declares externs, which unify
    // by symbol name), so attaching them again would duplicate every lua
    // symbol at link time.
    const declare_core_mod = b.createModule(.{
        .root_source_file = b.path("tools/declare/extract.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Its ruby twin (tools/declare-ruby): same promotion, same
    // no-C-sources rule — within the RUBY test binary the mruby objects
    // (and src/ruby/shim.c's flat exports) come from the ruby-language
    // module; tests/root.zig's comptime gate keeps this module unanalyzed
    // (and so unlinked) in every other language's binary.
    const declare_ruby_core_mod = b.createModule(.{
        .root_source_file = b.path("tools/declare-ruby/extract.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Its typescript twin (tools/declare-ts): same promotion, same
    // no-C-sources rule — within the TYPESCRIPT test binary the quickjs
    // objects come from the typescript-language module; tests/root.zig's
    // comptime gate keeps this module unanalyzed (and so unlinked) in every
    // other language's binary. Like the lua/ruby cores, the ts runner is an
    // embedded VM RUN in-process (unlike the rust/crystal probes).
    const declare_ts_core_mod = b.createModule(.{
        .root_source_file = b.path("tools/declare-ts/extract.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The CRYSTAL_LIBRARY_PATH splitter, promoted the same way (this
    // build script imports it directly; the eval shared suite unit-tests
    // its multi-entry behavior through the named module — same file, so
    // the code the wiring runs can never drift from the code under test).
    const crystal_lib_paths_mod = b.createModule(.{
        .root_source_file = b.path("tools/crystal_lib_paths.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── labelle-declare-rs: the rust declare-mode schema extractor ──────
    // The lua/ruby runners' native-family sibling (labelle-engine#774,
    // RFC-LANGUAGE-PLUGINS rev 17 §7). Rust has no interpreter, so this exe
    // is a COMPILE-AND-RUN PROBE: given `--cache-dir <dir>` + declaration
    // files, it stages a cargo crate under <dir> carrying the SHIPPED
    // labelle module's macros around those files, builds + runs it, and
    // prints the schema JSON. Same SHAPE as the lua/ruby steps below —
    // host-targeted, Debug-pinned, reached only through its named step (or
    // the rust test wiring, which drives THIS exe for the byte-parity pin).
    // It carries no vendored C runtime (the compile machinery is cargo,
    // shelled at runtime), only two build-time artifacts embedded as
    // anonymous imports its extract.zig @embedFile's: the SHIPPED
    // native/src/labelle.rs (the exact macro/emitter surface it was built
    // against) and the probe Cargo.toml template. Created ONCE here so the
    // named step and the test wiring share the artifact.
    const declare_rs_mod = b.createModule(.{
        .root_source_file = b.path("tools/declare-rs/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    declare_rs_mod.addAnonymousImport("labelle_rs_src", .{
        .root_source_file = b.path("native/src/labelle.rs"),
    });
    declare_rs_mod.addAnonymousImport("probe_cargo_toml", .{
        .root_source_file = b.path("tools/declare-rs/Cargo.toml"),
    });
    const declare_rs_exe = b.addExecutable(.{
        .name = "labelle-declare-rs",
        .root_module = declare_rs_mod,
    });
    const declare_rs_step = b.step(
        "labelle-declare-rs",
        "Build the rust declare-mode schema extractor (zig-out/bin/labelle-declare-rs)",
    );
    declare_rs_step.dependOn(&b.addInstallArtifact(declare_rs_exe, .{}).step);

    // ── labelle-declare-crystal: the crystal declare-mode schema extractor ──
    // rust's native-family TWIN (labelle-engine#775). Crystal has no
    // interpreter either, so this exe is the SAME COMPILE-AND-RUN PROBE: given
    // `--cache-dir <dir>` + declaration files, it stages a crystal program
    // under <dir> carrying the SHIPPED Labelle module's macros around those
    // files, `crystal build -Ddeclare`s + runs it, and prints the schema JSON.
    // Same SHAPE as the declare-rs step above — host-targeted, Debug-pinned,
    // reached only through its named step (or the crystal test wiring, which
    // drives THIS exe for the byte-parity pin). It carries no vendored runtime
    // (the compile machinery is `crystal`, shelled at runtime), only one
    // build-time artifact its extract.zig `@embedFile`s: the SHIPPED
    // native-crystal/src/labelle.cr (the exact macro/emitter surface it was
    // built against). Created ONCE here so the named step and the test wiring
    // share the artifact.
    const declare_crystal_mod = b.createModule(.{
        .root_source_file = b.path("tools/declare-crystal/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    declare_crystal_mod.addAnonymousImport("labelle_cr_src", .{
        .root_source_file = b.path("native-crystal/src/labelle.cr"),
    });
    const declare_crystal_exe = b.addExecutable(.{
        .name = "labelle-declare-crystal",
        .root_module = declare_crystal_mod,
    });
    const declare_crystal_step = b.step(
        "labelle-declare-crystal",
        "Build the crystal declare-mode schema extractor (zig-out/bin/labelle-declare-crystal)",
    );
    declare_crystal_step.dependOn(&b.addInstallArtifact(declare_crystal_exe, .{}).step);

    // ── labelle-declare-csharp: the C# declare-mode schema extractor ────────
    // rust's / crystal's CoreCLR-family TWIN (labelle-scripting#27,
    // labelle-engine#743). C# is compiled, so this exe is the SAME
    // COMPILE-AND-RUN PROBE: given `--cache-dir <dir>` + declaration files, it
    // stages a C# console program under <dir> carrying the SHIPPED Labelle
    // declare surface around those files, `dotnet build`s + runs it, and prints
    // the schema JSON. Same SHAPE as the declare-rs/declare-crystal steps above —
    // host-targeted, Debug-pinned, reached only through its named step (or the
    // csharp test wiring, which drives THIS exe for the byte-parity pin). It
    // carries no vendored runtime (the compile machinery is `dotnet`, shelled at
    // runtime), only one build-time artifact its extract.zig `@embedFile`s: the
    // SHIPPED native-csharp/src/Declare.cs (the exact declare surface/emitter it
    // was built against). Created ONCE here so the named step and the test wiring
    // share the artifact.
    const declare_csharp_mod = b.createModule(.{
        .root_source_file = b.path("tools/declare-csharp/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    declare_csharp_mod.addAnonymousImport("csharp_declare_src", .{
        .root_source_file = b.path("native-csharp/src/Declare.cs"),
    });
    const declare_csharp_exe = b.addExecutable(.{
        .name = "labelle-declare-csharp",
        .root_module = declare_csharp_mod,
    });
    const declare_csharp_step = b.step(
        "labelle-declare-csharp",
        "Build the C# declare-mode schema extractor (zig-out/bin/labelle-declare-csharp)",
    );
    declare_csharp_step.dependOn(&b.addInstallArtifact(declare_csharp_exe, .{}).step);

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
    //
    // `declare_core` is wired into every binary but the test root only
    // ANALYZES it under `.lua` (comptime gate) — its lua_* externs can
    // resolve only where the language module compiled lua in; module
    // analysis is lazy, so the ruby binary never touches it.
    const test_step = b.step("test", "Run all language suites against the mock host world");
    inline for (@typeInfo(Language).@"enum".fields) |field| {
        const lang: Language = @enumFromInt(field.value);
        // Labeled runtime block, not `continue`: skipping an iteration on
        // a RUNTIME condition is comptime control flow inside an inline
        // for (compile error) — breaking out of a runtime block is not.
        wire: {
            if (lang == .crystal and crystalTriple(b, target.result) == null) {
                // No crystal story for this target (Windows host, wasm
                // cross, exotic arch): skip BOTH crystal test binaries
                // instead of aborting configuration — every other
                // language still wires; CI's macOS/linux lanes keep
                // crystal covered.
                break :wire;
            }
            if (lang == .csharp and (!isDesktop(target.result.os.tag) or
                (b.findProgram(&.{"dotnet"}, &.{}) catch null) == null))
            {
                // C# scripting is CoreCLR-hosted (labelle-engine#743): its
                // suite needs the .NET SDK to compile the managed test
                // assembly and a desktop OS to host the runtime (mobile
                // AOT is out of v1). Skip the csharp test binary when
                // either is absent rather than aborting configuration —
                // every other language still wires; CI's desktop lanes
                // with dotnet installed keep csharp covered.
                break :wire;
            }
            const lang_mod = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            configureLanguage(b, lang_mod, lang, lua_dep_opt, quickjs_dep_opt);
            // The v1.3 probe's engine stand-in — see engine_stub_mod above.
            lang_mod.addImport("labelle-engine", engine_stub_mod);
            const tests_root_mod = b.createModule(.{
                .root_source_file = b.path("tests/root.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "labelle_scripting", .module = lang_mod },
                    .{ .name = "declare_core", .module = declare_core_mod },
                    .{ .name = "declare_ruby_core", .module = declare_ruby_core_mod },
                    .{ .name = "declare_ts_core", .module = declare_ts_core_mod },
                    .{ .name = "crystal_lib_paths", .module = crystal_lib_paths_mod },
                },
            });
            // The pack hook shim's SOURCE, for the eval shared suite's AstGen
            // compile check (tests/eval_shared_suite.zig): the file itself can
            // only compile inside a generated game (it imports labelle-engine),
            // so the suite `@embedFile`s it through this anonymous import and
            // runs parse + AstGen — the strongest engine-free verification.
            tests_root_mod.addAnonymousImport("console_eval_shim_src", .{
                .root_source_file = b.path("packs/scripting_console/hooks/console_eval.zig"),
            });
            // Both manifests, for the shared suite's packaging-consistency pin:
            // every unit plugin.labelle references (bundled packs, convention
            // dirs) must be covered by build.zig.zon's `.paths` whitelist — a
            // referenced-but-unshipped directory would hand consumers a
            // manifest pointing at content their fetched copy doesn't have.
            tests_root_mod.addAnonymousImport("plugin_labelle_src", .{
                .root_source_file = b.path("plugin.labelle"),
            });
            tests_root_mod.addAnonymousImport("build_zig_zon_src", .{
                .root_source_file = b.path("build.zig.zon"),
            });
            // The sources carrying the ruby view fast path's field cap,
            // for tests/declare_ruby_tool.zig's drift pin: the cap is one
            // number spelled in several languages (Zig buffer sizing,
            // runtime construction check, declare-time checks — including
            // the lua declare prelude's event-cap twin, MAX_EVENT_FIELDS),
            // so the pin reads each literal out of its source and asserts
            // equality — the packaging pins' technique.
            tests_root_mod.addAnonymousImport("ruby_bindings_src", .{
                .root_source_file = b.path("src/ruby/bindings.zig"),
            });
            tests_root_mod.addAnonymousImport("ruby_prelude_src", .{
                .root_source_file = b.path("src/ruby/prelude.rb"),
            });
            tests_root_mod.addAnonymousImport("declare_ruby_prelude_src", .{
                .root_source_file = b.path("tools/declare-ruby/declare_prelude.rb"),
            });
            tests_root_mod.addAnonymousImport("declare_lua_prelude_src", .{
                .root_source_file = b.path("tools/declare/declare_prelude.lua"),
            });
            const tests = b.addTest(.{
                .root_module = tests_root_mod,
            });

            // The rust binary's staticlib (labelle-engine#741): the suite links
            // the crate the tests drive — the SHIPPED glue + labelle module
            // (native/src/, recomposed by #[path] around tests/rust/game/'s
            // scenario scripts; see tests/rust/src/lib.rs). cargo builds it
            // with a persistent --target-dir under the zig cache so edits
            // rebuild in cargo-incremental time; the Run step declares no
            // outputs, so zig re-runs it every build and cargo's own
            // staleness check (a few ms when clean) is the cache. `--locked`
            // pins the committed Cargo.lock (zero deps — no network, ever).
            // Local dev needs a rust toolchain (rustc ≥ 1.82), same as CI.
            if (lang == .rust) {
                const rust_target_dir = b.cache_root.join(
                    b.allocator,
                    &.{"rust-suite-target"},
                ) catch @panic("OOM");
                const cargo = b.addSystemCommand(&.{
                    "cargo",     "build",
                    "--release", "--quiet",
                    "--locked",  "--manifest-path",
                });
                cargo.addFileArg(b.path("tests/rust/Cargo.toml"));
                cargo.addArgs(&.{ "--target-dir", rust_target_dir });
                tests.step.dependOn(&cargo.step);
                tests_root_mod.addObjectFile(.{ .cwd_relative = b.fmt(
                    "{s}/release/liblabelle_rust_scripts_test.a",
                    .{rust_target_dir},
                ) });
                // panic = "unwind" (load-bearing — the glue's catch_unwind is
                // under test) needs an unwinder at link time. macOS: libSystem
                // carries it (link_libc). Linux-gnu: rustc links libgcc_s for
                // its staticlibs' _Unwind_* — mirror it here.
                if (target.result.os.tag == .linux) {
                    tests_root_mod.linkSystemLibrary("gcc_s", .{});
                }

                // The declare tool (labelle-engine#774, rev 17): the rust
                // member of the cross-runner byte-parity contract. Rust has no
                // interpreter, so — unlike lua/ruby, RUN in-process through the
                // declare_core externs — the runner is the labelle-declare-rs
                // exe (built above), which cargo-BUILDS a probe INTERNALLY. The
                // test drives the SHIPPED tool exactly as the assembler will:
                // `labelle-declare-rs --cache-dir <persistent> <components.rs>
                // <events.rs>` over the GAME-SHAPED fixtures (bare macros, NO
                // `use` lines — a green run proves the tool's injected prelude).
                // Its captured stdout is `@embedFile`d by
                // tests/declare_rust_tool.zig and pinned byte-identical to the
                // lua/ruby runners' schema. The --cache-dir is a persistent dir
                // under the zig cache the tool uses as the cargo --target-dir,
                // so a re-extract is warm. Host-targeted: the tool runs at build
                // time on the dev/CI machine, whatever the game targets.
                const declare_rs_cache = b.cache_root.join(
                    b.allocator,
                    &.{"rust-declare-target"},
                ) catch @panic("OOM");
                const run_tool = b.addRunArtifact(declare_rs_exe);
                run_tool.addArgs(&.{ "--cache-dir", declare_rs_cache });
                run_tool.addFileArg(b.path("tools/declare-rs/testdata/components.rs"));
                run_tool.addFileArg(b.path("tools/declare-rs/testdata/events.rs"));
                const tool_out = run_tool.captureStdOut(.{});
                tests_root_mod.addAnonymousImport("rust_declare_schema_out", .{
                    .root_source_file = tool_out,
                });
                tests_root_mod.addAnonymousImport("declare_rs_components_src", .{
                    .root_source_file = b.path("tools/declare-rs/testdata/components.rs"),
                });
                tests_root_mod.addAnonymousImport("declare_rs_events_src", .{
                    .root_source_file = b.path("tools/declare-rs/testdata/events.rs"),
                });
            }

            // The crystal binary's script object (labelle-engine#741, second
            // native language): the SHIPPED glue + labelle module recomposed
            // around tests/crystal/game/'s scenario scripts by relative
            // `require`s (tests/crystal/main.cr — crystal's spelling of the
            // rust suite's #[path] recomposition). Two chained steps, the
            // POC-proven recipe: `crystal build --cross-compile` emits an
            // object (crystal has no --no-main, so it carries a `main`), then
            // a localization pass demotes every symbol except the entry
            // points so nothing collides with the test binary's own `main`.
            // Objects land under the zig cache; crystal's own source cache
            // (CRYSTAL_CACHE_DIR) plays cargo's staleness-check role.
            if (lang == .crystal) {
                const crystal_cache = b.cache_root.join(
                    b.allocator,
                    &.{"crystal-suite-target"},
                ) catch @panic("OOM");
                b.cache_root.handle.createDirPath(b.graph.io, "crystal-suite-target") catch @panic("mkdir crystal-suite-target");
                const obj_base = b.fmt("{s}/labelle_crystal_scripts_test", .{crystal_cache});
                const obj_path = b.fmt("{s}.o", .{obj_base});
                const lib_obj_path = b.fmt("{s}_lib.o", .{obj_base});

                const crystal_build = b.addSystemCommand(&.{
                    "crystal",                         "build",
                    "--cross-compile",                 "--target",
                    crystalTriple(b, target.result).?,
                });
                crystal_build.addFileArg(b.path("tests/crystal/main.cr"));
                crystal_build.addArgs(&.{ "-o", obj_base });

                // Localize `main` (and every other non-entry symbol): the
                // per-OS tools differ but the semantics are identical — the
                // listed labelle_cr_* symbols stay global, everything else
                // (main, the whole crystal runtime) goes local; UNDEFINED
                // symbols (the contract externs, the suite's test-scenario
                // export) stay linkable on both tools. The SHIPPED lists
                // are used on purpose — the suite proving them sufficient
                // is part of the coverage. The two files differ only in
                // macOS's leading-underscore mangling.
                const localize = switch (target.result.os.tag) {
                    .macos => blk: {
                        const step = b.addSystemCommand(&.{
                            "ld",         "-r",
                            obj_path,     "-o",
                            lib_obj_path, "-exported_symbols_list",
                        });
                        step.addFileArg(b.path("native-crystal/exported_symbols_macos.txt"));
                        break :blk step;
                    },
                    .linux => blk: {
                        const step = b.addSystemCommand(&.{"objcopy"});
                        step.addPrefixedFileArg(
                            "--keep-global-symbols=",
                            b.path("native-crystal/exported_symbols_linux.txt"),
                        );
                        step.addArgs(&.{ obj_path, lib_obj_path });
                        break :blk step;
                    },
                    else => @panic("crystal language tests: unsupported host OS (desktop-only, macOS/linux)"),
                };
                localize.step.dependOn(&crystal_build.step);
                tests.step.dependOn(&localize.step);
                tests_root_mod.addObjectFile(.{ .cwd_relative = lib_obj_path });

                // The search paths come from `crystal env
                // CRYSTAL_LIBRARY_PATH` — a COLON-SEPARATED list
                // (tools/crystal_lib_paths.zig is the splitting point,
                // tested in the eval shared suite): each entry is exactly
                // where `crystal build` itself points its link line (brew's
                // /opt/homebrew/lib, the official linux tarball's bundled
                // lib/crystal/, any user-prepended dirs). Resolved only when
                // crystal exists so a crystal-less `zig build --help` still
                // configures — the crystal_build step above is what fails
                // loudly then. Collected once: two binaries link the object
                // (below).
                var crystal_lib_dirs: std.ArrayList([]const u8) = .empty;
                if (b.findProgram(&.{"crystal"}, &.{}) catch null) |crystal_exe| {
                    const lib_path_raw = b.run(&.{ crystal_exe, "env", "CRYSTAL_LIBRARY_PATH" });
                    var lib_paths = crystal_lib_paths.iterate(lib_path_raw);
                    while (lib_paths.next()) |entry| {
                        crystal_lib_dirs.append(b.allocator, entry) catch @panic("OOM");
                    }
                }
                linkCrystalRuntime(tests_root_mod, target.result.os.tag, crystal_lib_dirs.items);

                // The BOOT-containment binary (tests/crystal_boot_suite.zig):
                // a failed boot POISONS crystal scripting process-wide (see
                // src/crystal/vm.zig's runtime_boot_poisoned), so its pin
                // cannot share a process with the main suite — same localized
                // object, same mock world, its own test binary.
                const boot_root_mod = b.createModule(.{
                    .root_source_file = b.path("tests/crystal_boot_suite.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "labelle_scripting", .module = lang_mod },
                    },
                });
                boot_root_mod.addObjectFile(.{ .cwd_relative = lib_obj_path });
                linkCrystalRuntime(boot_root_mod, target.result.os.tag, crystal_lib_dirs.items);
                const boot_tests = b.addTest(.{
                    .root_module = boot_root_mod,
                });
                boot_tests.step.dependOn(&localize.step);
                const run_boot_tests = b.addRunArtifact(boot_tests);
                test_step.dependOn(&run_boot_tests.step);

                // The declare tool (labelle-engine#775) — the crystal member of
                // the cross-runner byte-parity contract, rust's twin. Crystal
                // has no interpreter, so — unlike lua/ruby, RUN in-process — the
                // runner is the labelle-declare-crystal exe (built above), which
                // `crystal build`s a probe INTERNALLY. The test drives the
                // SHIPPED tool exactly as the assembler will:
                // `labelle-declare-crystal --cache-dir <persistent>
                // <components.cr> <events.cr>` over the GAME-SHAPED fixtures
                // (bare macros, NO `require` lines — a green run proves the
                // tool's injected prelude). Its captured stdout is `@embedFile`d
                // by tests/declare_crystal_tool.zig and pinned byte-identical to
                // the lua/ruby/rust runners' schema. The --cache-dir is a
                // persistent dir under the zig cache the tool uses as the
                // crystal compile cache (CRYSTAL_CACHE_DIR), so a re-extract is
                // warm — crystal's whole-program compile is slow. Host-targeted:
                // the tool runs at build time on the dev/CI machine, whatever
                // the game targets. Rides the crystal-present wiring (this
                // block), so a crystal-less host never reaches it.
                const declare_crystal_cache = b.cache_root.join(
                    b.allocator,
                    &.{"crystal-declare-target"},
                ) catch @panic("OOM");
                const run_crystal_tool = b.addRunArtifact(declare_crystal_exe);
                run_crystal_tool.addArgs(&.{ "--cache-dir", declare_crystal_cache });
                run_crystal_tool.addFileArg(b.path("tools/declare-crystal/testdata/components.cr"));
                run_crystal_tool.addFileArg(b.path("tools/declare-crystal/testdata/events.cr"));
                const crystal_tool_out = run_crystal_tool.captureStdOut(.{});
                tests_root_mod.addAnonymousImport("crystal_declare_schema_out", .{
                    .root_source_file = crystal_tool_out,
                });
                tests_root_mod.addAnonymousImport("declare_cr_components_src", .{
                    .root_source_file = b.path("tools/declare-crystal/testdata/components.cr"),
                });
                tests_root_mod.addAnonymousImport("declare_cr_events_src", .{
                    .root_source_file = b.path("tools/declare-crystal/testdata/events.cr"),
                });
            }

            // The csharp binary's managed test assembly (labelle-engine
            // #743): unlike rust/crystal there is no object to LINK — C#
            // is CoreCLR-hosted, so the assembly is loaded at RUNTIME. The
            // `dotnet build` step compiles the SHIPPED glue + Labelle
            // module (native-csharp/src/, recomposed by the test csproj's
            // <Compile> globs around tests/csharp/game/'s scenario scripts)
            // into `labelle_csharp_scripts.dll` + its runtimeconfig.json in
            // a cache dir; the test binary is built `rdynamic` so its
            // mock-world contract exports are visible to the managed
            // assembly's [LibraryImport] resolver (GetMainProgramHandle),
            // exactly as a shipped game host must export them. The run step
            // points the VM at the built assembly via LABELLE_CS_ASSEMBLY_DIR
            // (src/csharp/vm.zig's documented override). Local dev / CI need
            // the .NET SDK on PATH (the wire-skip above gates it).
            var csharp_out_dir: []const u8 = "";
            if (lang == .csharp) {
                csharp_out_dir = b.cache_root.join(b.allocator, &.{"csharp-suite-out"}) catch @panic("OOM");
                const dotnet = b.addSystemCommand(&.{
                    "dotnet",       "build",
                    "-c",           "Release",
                    "--nologo",     "-v",
                    "quiet",        "-o",
                    csharp_out_dir,
                });
                dotnet.addFileArg(b.path("tests/csharp/LabelleScriptsTest.csproj"));
                tests.step.dependOn(&dotnet.step);
                // Export the mock-world contract symbols so the managed
                // assembly can bind them against the host process.
                tests.rdynamic = true;

                // The declare tool (labelle-scripting#27, labelle-engine#743) —
                // the C# member of the cross-runner byte-parity contract, rust's
                // / crystal's CoreCLR-family twin. C# is compiled, so — unlike
                // lua/ruby, RUN in-process — the runner is the
                // labelle-declare-csharp exe (built above), which `dotnet build`s
                // a probe INTERNALLY. The test drives the SHIPPED tool exactly as
                // the assembler will: `labelle-declare-csharp --cache-dir
                // <persistent> <components.cs> <events.cs>` over the GAME-SHAPED
                // fixtures (bare attributed records, NO `using` lines — a green
                // run proves the tool needs no prelude injection). Its captured
                // stdout is `@embedFile`d by tests/declare_csharp_tool.zig and
                // pinned byte-identical to the lua/ruby/rust/crystal/ts runners'
                // schema. The --cache-dir is a persistent dir under the zig cache
                // the tool reuses as dotnet's build workspace (obj/), so a
                // re-extract is warm. Host-targeted: the tool runs at build time
                // on the dev/CI machine, whatever the game targets. Rides the
                // dotnet-present wiring (this block), so a dotnet-less host never
                // reaches it.
                const declare_csharp_cache = b.cache_root.join(
                    b.allocator,
                    &.{"csharp-declare-target"},
                ) catch @panic("OOM");
                const run_csharp_tool = b.addRunArtifact(declare_csharp_exe);
                run_csharp_tool.addArgs(&.{ "--cache-dir", declare_csharp_cache });
                run_csharp_tool.addFileArg(b.path("tools/declare-csharp/testdata/components.cs"));
                run_csharp_tool.addFileArg(b.path("tools/declare-csharp/testdata/events.cs"));
                const csharp_tool_out = run_csharp_tool.captureStdOut(.{});
                tests_root_mod.addAnonymousImport("csharp_declare_schema_out", .{
                    .root_source_file = csharp_tool_out,
                });
                tests_root_mod.addAnonymousImport("declare_cs_components_src", .{
                    .root_source_file = b.path("tools/declare-csharp/testdata/components.cs"),
                });
                tests_root_mod.addAnonymousImport("declare_cs_events_src", .{
                    .root_source_file = b.path("tools/declare-csharp/testdata/events.cs"),
                });
            }

            const run_tests = b.addRunArtifact(tests);
            if (lang == .csharp) run_tests.setEnvironmentVariable("LABELLE_CS_ASSEMBLY_DIR", csharp_out_dir);
            test_step.dependOn(&run_tests.step);
        }
    }

    // ── labelle-declare: the declare-mode schema extractor ──────────────
    // (RFC-LANGUAGE-PLUGINS revs 6-7, labelle-engine#237.) A tiny host exe
    // the assembler builds + runs at GENERATE time (`zig build
    // labelle-declare`, labelle-assembler#585): it loads each game script's
    // chunk body against a stub `labelle` and prints the declared-component
    // schema JSON on stdout. Deliberately host-targeted and Debug-pinned —
    // it never ships in a game, whatever -Dtarget/-Doptimize the consuming
    // game build passes — and built regardless of -Dlanguage since it
    // embeds lua directly (its OWN copy of the C sources: the exe is a
    // separate compilation, nothing is compiled twice into one binary).
    // Reached only through its named step, so plain `zig build` / consumer
    // dependency wiring never pays for it.
    if (lua_dep_opt) |lua_dep| {
        const declare_mod = b.createModule(.{
            .root_source_file = b.path("tools/declare/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
        });
        declare_mod.addIncludePath(lua_dep.path("src"));
        declare_mod.addCSourceFiles(.{
            .root = lua_dep.path("src"),
            .files = &lua_sources,
        });
        const declare_exe = b.addExecutable(.{
            .name = "labelle-declare",
            .root_module = declare_mod,
        });
        const declare_step = b.step(
            "labelle-declare",
            "Build the declare-mode schema extractor (zig-out/bin/labelle-declare)",
        );
        declare_step.dependOn(&b.addInstallArtifact(declare_exe, .{}).step);
    }

    // ── labelle-declare-ruby: the ruby declare-mode schema extractor ────
    // The lua runner's per-language sibling — one runner exe per script
    // language, selected by the assembler's declare phase through the
    // per-language STEP NAME (a lua game never compiles mruby at generate
    // time and vice versa; capability probes stay filesystem-simple:
    // tools/declare-ruby exists ⇒ this step exists). Same shape as above:
    // host-targeted, Debug-pinned, reached only through its named step —
    // and no lazy-dep gate, because mruby is the in-repo vendor snapshot.
    // The exe compiles its OWN copy of the mruby objects (+ shim.c), like
    // the lua exe does with lua: a separate compilation, nothing doubled.
    {
        const declare_ruby_mod = b.createModule(.{
            .root_source_file = b.path("tools/declare-ruby/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
        });
        declare_ruby_mod.addIncludePath(b.path("vendor/mruby/include"));
        declare_ruby_mod.addCSourceFiles(.{
            .root = b.path("vendor/mruby"),
            .files = &mruby_sources,
            .flags = &mruby_defines,
        });
        declare_ruby_mod.addCSourceFile(.{
            .file = b.path("src/ruby/shim.c"),
            .flags = &mruby_defines,
        });
        const declare_ruby_exe = b.addExecutable(.{
            .name = "labelle-declare-ruby",
            .root_module = declare_ruby_mod,
        });
        const declare_ruby_step = b.step(
            "labelle-declare-ruby",
            "Build the ruby declare-mode schema extractor (zig-out/bin/labelle-declare-ruby)",
        );
        declare_ruby_step.dependOn(&b.addInstallArtifact(declare_ruby_exe, .{}).step);
    }

    // ── labelle-declare-ts: the typescript declare-mode schema extractor ────
    // The lua/ruby runners' embedded-VM sibling (RFC-LANGUAGE-PLUGINS rev 20,
    // labelle-engine#773). Same shape as the lua `labelle-declare` step:
    // host-targeted, Debug-pinned, reached only through its named step. Under
    // the assembler's rev-20 option (b) it receives the EMITTED `.js` (the
    // assembler transpiles `components/*.ts` + `events/*.ts` FIRST), so the
    // tool is a pure quickjs evaluator that knows NOTHING about tsc. It
    // compiles its OWN copy of the quickjs-ng sources (+ abi_check.c, the
    // _Static_asserts pinning the hand-mirrored JSValue layout the extractor's
    // C API relies on) — a separate compilation, nothing doubled — behind the
    // same lazy-dependency gate the typescript LANGUAGE arm uses, so a `zig
    // build --help` on a machine that never fetched quickjs still configures.
    if (quickjs_dep_opt) |qjs_dep| {
        const declare_ts_mod = b.createModule(.{
            .root_source_file = b.path("tools/declare-ts/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
        });
        declare_ts_mod.addIncludePath(qjs_dep.path("."));
        declare_ts_mod.addCSourceFiles(.{
            .root = qjs_dep.path("."),
            .files = &quickjs_sources,
            .flags = &quickjs_flags,
        });
        declare_ts_mod.addCSourceFile(.{
            .file = b.path("src/ts/abi_check.c"),
            .flags = &quickjs_flags,
        });
        const declare_ts_exe = b.addExecutable(.{
            .name = "labelle-declare-ts",
            .root_module = declare_ts_mod,
        });
        const declare_ts_step = b.step(
            "labelle-declare-ts",
            "Build the typescript declare-mode schema extractor (zig-out/bin/labelle-declare-ts)",
        );
        declare_ts_step.dependOn(&b.addInstallArtifact(declare_ts_exe, .{}).step);
    }
}

/// Wire `mod` for one language: the `scripting_options` module feeding
/// src/root.zig's comptime backend switch, plus the language's vendored
/// runtime sources. Unselected runtimes are not compiled into the module
/// (the lua FETCH is unconditional — see build(), the declare extractor
/// needs it — but its objects only enter the module here).
fn configureLanguage(
    b: *std.Build,
    mod: *std.Build.Module,
    language: Language,
    lua_dep_opt: ?*std.Build.Dependency,
    quickjs_dep_opt: ?*std.Build.Dependency,
) void {
    const opts = b.addOptions();
    opts.addOption(Language, "language", language);
    mod.addOptions("scripting_options", opts);

    switch (language) {
        .lua => if (lua_dep_opt) |lua_dep| {
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
        .typescript => if (quickjs_dep_opt) |qjs_dep| {
            // Vendored quickjs-ng (see quickjs_sources) plus
            // src/ts/abi_check.c — no runtime shim, only _Static_asserts
            // pinning the header facts the Zig bindings hand-mirror
            // (JSValue layout, tag numbering, flag values), compiled
            // against the SAME fetched headers and defines so a future
            // pin bump that moves any of them fails the build instead of
            // corrupting values at runtime. Everything the bindings call
            // is a real exported symbol in quickjs-ng v0.15+ (unlike
            // mruby, where the macro layer forced a functional shim).
            mod.addIncludePath(qjs_dep.path("."));
            mod.addCSourceFiles(.{
                .root = qjs_dep.path("."),
                .files = &quickjs_sources,
                .flags = &quickjs_flags,
            });
            mod.addCSourceFile(.{
                .file = b.path("src/ts/abi_check.c"),
                .flags = &quickjs_flags,
            });
        },
        .rust => {
            // Native-compiled (labelle-engine#741): NOTHING is vendored or
            // compiled into the module — src/rust/vm.zig is pure Zig
            // declaring the crate glue's labelle_rs_* externs. The
            // staticlib that defines them (native/'s crate, carrying the
            // GAME's rust/ sources as its `game` module) is built by
            // cargo OUTSIDE this module and linked onto the final binary:
            // in consumer games by the assembler's declared build step
            // (plugin.labelle `.language_builds`), in this repo's own
            // suite by the test-loop wiring below. Keeping cargo out of
            // the module means a consumer's `b.dependency` never shells
            // out — external builds stay declared, auditable steps.
        },
        .crystal => {
            // Native-compiled, rust's twin: src/crystal/vm.zig declares
            // the glue's labelle_cr_* externs; the object that defines
            // them (native-crystal/'s sources carrying the GAME's
            // crystal/ dir as its `game` module) is built by the two
            // declared steps — crystal build, then main-localization —
            // and linked onto the final binary the same two ways (the
            // assembler's `.language_builds` steps in consumer games,
            // the test-loop wiring in this repo's suite).
        },
        .csharp => {
            // CoreCLR host (labelle-engine#743): NOTHING is vendored,
            // compiled or LINKED into the Zig module — src/csharp/vm.zig
            // is pure Zig that loads a managed assembly at RUNTIME through
            // hostfxr. The assembly (native-csharp/'s C# sources carrying
            // the GAME's csharp/ dir as its `Game` module) is produced by
            // the declared `dotnet` build step (plugin.labelle
            // `.language_builds`) and rides BESIDE the game binary, not
            // inside it — so unlike rust/crystal there is no object to add
            // to the module here.
        },
    }
}

/// The crystal runtime's system libraries + search paths — mirror of
/// plugin.labelle's crystal `.system_libs`/`.library_paths` (what the
/// assembler row will link in consumer games): bdw-gc always, pcre2
/// because game scripts may use Regex, iconv on macOS only (String
/// encodings; glibc builds it in), gcc_s on linux (the unwinder —
/// crystal's begin/rescue needs _Unwind_*, and the object's references
/// are libgcc's because crystal links through the gcc driver; same
/// spelling the rust wiring uses for panic=unwind, proven on this
/// repo's ubuntu lane — see the plugin.labelle crystal entry's comment
/// for the full rationale). crystal 1.15+'s event loop is
/// kqueue/epoll-native — no libevent. Shared by the two crystal test
/// binaries (main suite + boot suite).
fn linkCrystalRuntime(mod: *std.Build.Module, os_tag: std.Target.Os.Tag, lib_dirs: []const []const u8) void {
    for (lib_dirs) |dir| {
        mod.addLibraryPath(.{ .cwd_relative = dir });
    }
    mod.linkSystemLibrary("gc", .{});
    mod.linkSystemLibrary("pcre2-8", .{});
    switch (os_tag) {
        .macos => mod.linkSystemLibrary("iconv", .{}),
        else => {
            mod.linkSystemLibrary("gcc_s", .{});
            // glibc-hosted: crystal's own link line adds these (modern
            // glibc folds most in, the stubs stay safe).
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("rt", .{});
            mod.linkSystemLibrary("m", .{});
        },
    }
}

/// The `--target` triple `crystal build --cross-compile` needs, from the
/// zig target — desktop-only, matching the crystal `.language_builds`
/// entry's platform allowlist in plugin.labelle.
/// Null when the target has no crystal story (desktop-only, macOS/linux,
/// aarch64/x86_64) — callers SKIP rather than fail: this runs at build-
/// script configure time for every language's test graph, so a panic here
/// would abort `zig build --help` on a Windows host or a wasm cross for a
/// game that never selected crystal.
/// The desktop OSes the csharp CoreCLR host targets in v1 (mobile AOT is
/// out of scope — labelle-engine#743). Gates the csharp test binary's
/// wiring the way `crystalTriple` gates crystal's.
fn isDesktop(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .windows, .macos, .linux => true,
        else => false,
    };
}

fn crystalTriple(b: *std.Build, t: std.Target) ?[]const u8 {
    const arch = switch (t.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return null,
    };
    return switch (t.os.tag) {
        .macos => b.fmt("{s}-apple-darwin", .{arch}),
        .linux => b.fmt("{s}-linux-gnu", .{arch}),
        else => null,
    };
}
