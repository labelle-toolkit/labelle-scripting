//! labelle-scripting acceptance tests: the SELECTED language sub-module
//! driven end to end against the mock host world (tests/mock_world.zig).
//!
//! The linking model IS the production one — src/contract.zig declares the
//! `labelle_*` symbols `extern`, mock_world.zig `export`s them into this
//! test binary, exactly as the assembler-generated game will. So every
//! assertion here exercises the same seam a shipped game uses; only the
//! world behind the symbols is a toy — and it is language-agnostic: every
//! suite runs against the same mock.
//!
//! One test binary per language: build.zig instantiates this root once
//! per `Language` value and the comptime switch below pulls in that
//! language's suite; `zig build test` runs them all.
//!
//! Test hygiene (applies to every suite): plugin VM + registry + mock
//! world are process-global (the contract is process-global by nature),
//! so every test starts with `fresh()` and tears its VM down via defer.

const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

// Force semantic analysis of the mock so its `export fn labelle_*` symbols
// are emitted — the plugin's externs resolve against them at link time.
comptime {
    _ = mock;
}

test {
    _ = switch (scripting.language) {
        .lua => @import("lua_suite.zig"),
        .ruby => @import("ruby_suite.zig"),
        .typescript => @import("ts_suite.zig"),
        .rust => @import("rust_suite.zig"),
        .crystal => @import("crystal_suite.zig"),
        .csharp => @import("csharp_suite.zig"),
    };
}

// The declare-mode extractor goldens (tools/declare via the `declare_core`
// named module) ride the LUA test binary only: extract.zig's lua_* externs
// resolve against the lua objects the lua-language module compiled in —
// the ruby binary carries mruby, no lua symbols. The comptime gate keeps
// the module unanalyzed (and so unlinked) everywhere else.
comptime {
    if (scripting.language == .lua) _ = @import("declare_tool.zig");
}

// The RUBY declare runner's goldens (tools/declare-ruby via
// `declare_ruby_core`) ride the RUBY binary the same way: its mrb_* and
// labelle_mrb_* externs resolve against the mruby objects (+ shim.c) the
// ruby-language module compiled in. The cross-runner byte-parity golden
// lives in BOTH files through tests/declare_cross_golden.zig's shared
// expected-JSON literal — each binary pins its own runner against it.
comptime {
    if (scripting.language == .ruby) _ = @import("declare_ruby_tool.zig");
}

// The TYPESCRIPT declare runner's goldens (tools/declare-ts via
// `declare_ts_core`) ride the TYPESCRIPT binary the same way (labelle-engine
// #773, rev 20): its JS_* externs resolve against the quickjs objects the
// typescript-language module compiled in. Like lua/ruby it RUNS in-process
// (unlike the rust/crystal probes); the cross-runner byte-parity golden lives
// in tests/declare_cross_golden.zig's shared expected-JSON literal.
comptime {
    if (scripting.language == .typescript) _ = @import("declare_ts_tool.zig");
}

// The RUST declare runner's golden (labelle-engine#774) rides the RUST binary
// only. It needs no in-process externs — the runner is an out-of-process probe
// build.zig cargo-builds and RUNS, `@embedFile`ing its stdout — but the gate
// keeps the two anonymous imports (the probe's captured output + the compiled
// fixture) analyzed only where build.zig actually wired them (lang == .rust).
comptime {
    if (scripting.language == .rust) _ = @import("declare_rust_tool.zig");
}

// The CRYSTAL declare runner's golden (labelle-engine#775) rides the CRYSTAL
// binary only — rust's twin. Like rust it needs no in-process externs (the
// runner is an out-of-process probe build.zig `crystal build`s and RUNS,
// `@embedFile`ing its stdout), and build.zig wires the three anonymous imports
// (captured output + the two compiled fixtures) only where crystal exists and
// the target has a crystal story (lang == .crystal, crystalTriple != null).
comptime {
    if (scripting.language == .crystal) _ = @import("declare_crystal_tool.zig");
}

// The CSHARP declare runner's golden (labelle-scripting#27, labelle-engine#743)
// rides the CSHARP binary only — rust's / crystal's CoreCLR-family twin. Like
// them it needs no in-process externs (the runner is an out-of-process probe
// build.zig `dotnet build`s and RUNS, `@embedFile`ing its stdout), and build.zig
// wires the three anonymous imports (captured output + the two compiled fixtures)
// only where the .NET SDK exists and the target is desktop (lang == .csharp,
// dotnet present) — the same gate that governs whether the csharp binary is
// built at all.
comptime {
    if (scripting.language == .csharp) _ = @import("declare_csharp_tool.zig");
}

// The console-eval SHARED-code suite (response builder, params decoding,
// hook-shim AstGen check — labelle-scripting#4) also rides the lua binary
// only: the code under test is language-independent, so one mirror is the
// whole coverage. Each language's eval CORE (Vm.evalConsole) is tested in
// its own suite.
comptime {
    if (scripting.language == .lua) _ = @import("eval_shared_suite.zig");
}

test "dispatch contract (#3): explicit-tick-only, zero-arg deinit" {
    // The assembler's splice (labelle-assembler#596) emits
    // `scripting.Controller.tick(&g, scaled_dt)` EXPLICITLY and selects
    // the generated deinit call by arity. @compileError (not assert —
    // a failed comptime assert prints a message-less 'unreachable code')
    // so the offender lands on the coordination requirement directly.
    // See the Controller doc in src/root.zig.
    comptime {
        if (@hasDecl(scripting, "Systems") or @hasDecl(scripting.Controller, "Systems"))
            @compileError("dispatch contract (labelle-scripting#3): a Systems decl " ++
                "would be auto-ticked by the engine ON TOP of the splice's explicit " ++
                "Controller.tick, double-ticking every scripted game — coordinate an " ++
                "assembler release before adding one (see src/root.zig Controller doc)");
        const deinit_info = @typeInfo(@TypeOf(scripting.Controller.deinit)).@"fn";
        if (deinit_info.params.len != 0)
            @compileError("dispatch contract (labelle-scripting#3): generated deinit " ++
                "blocks select the ZERO-ARG arm by arity — changing Controller.deinit's " ++
                "signature breaks every generated game; coordinate an assembler release");
        const tick_info = @typeInfo(@TypeOf(scripting.Controller.tick)).@"fn";
        // params[1].type is null for anytype — that shape change must land
        // on the coordination message too, not on a generic null unwrap.
        if (tick_info.params.len != 2 or
            tick_info.params[1].type == null or
            tick_info.params[1].type.? != f32)
            @compileError("dispatch contract (labelle-scripting#3): the splice emits " ++
                "Controller.tick(&g, scaled_dt) — the (anytype, f32) shape is frozen; " ++
                "coordinate an assembler release before changing it");
    }
}
