//! labelle-scripting — script labelle games in non-Zig languages.
//!
//! This module is the SHARED plugin glue: the plugin `Controller`
//! (RFC-plugin-controllers shape — `setup`/`tick`/`deinit`, wired by the
//! assembler like any other plugin) plus `registerScript`, the seam the
//! generated game feeds embedded script sources through, plus the studio
//! Script Console's eval core (`Controller.evalCommand` /
//! `handleEvalCommand` — labelle-scripting#4; the engine-coupled hook
//! shim rides the bundled `scripting_console` pack). Everything
//! game-facing goes through the Script Runtime Contract
//! (labelle-engine/contract/labelle_script.h, declared once in
//! src/contract.zig): the host game exports ~15 flat C symbols in its own
//! binary and this plugin's bindings call them. That indirection is the
//! entire design — the plugin never sees the game's Zig types, so ONE
//! compiled surface serves every game and, eventually, every language.
//!
//! The `game: anytype` parameters are accepted and ignored on purpose:
//! they keep the controller shape identical to Zig-native plugins (the
//! assembler wires all plugins uniformly), while the actual world access
//! rides the C contract.
//!
//! Language sub-modules: build.zig selects exactly one (`-Dlanguage=lua`,
//! `-Dlanguage=ruby` or `-Dlanguage=typescript`) and surfaces the choice
//! through the `scripting_options` module; the comptime switch below is
//! what keeps unselected backends out of analysis entirely. Each backend
//! directory (src/lua/, src/ruby/, src/ts/, …) exposes the same tiny
//! surface: `vm.Vm` (init/close/loadScript/callScriptHook/evictScript/
//! callLabelleFn) and `bindings.install`.

const std = @import("std");
const build_options = @import("scripting_options");

pub const contract = @import("contract.zig");

/// Console-eval shared pieces (labelle-scripting#4): result shape, params
/// decoding, bounded response-JSON builder. Engine-free — see
/// `Controller.evalCommand` / `handleEvalCommand` below for the seams.
pub const eval = @import("eval.zig");

/// The selected language (introspection/tests — the test root switches
/// its suite on this).
pub const language = build_options.language;

/// The active language backend, resolved at comptime from the build
/// option. Adding a language = new `src/<lang>/` + one arm here.
const Backend = switch (build_options.language) {
    .lua => struct {
        pub const vm = @import("lua/vm.zig");
        pub const bindings = @import("lua/bindings.zig");
    },
    .ruby => struct {
        pub const vm = @import("ruby/vm.zig");
        pub const bindings = @import("ruby/bindings.zig");
    },
    .typescript => struct {
        pub const vm = @import("ts/vm.zig");
        pub const bindings = @import("ts/bindings.zig");
    },
};

/// One registered script: a stable name (chunkname for error reporting,
/// registry key for hook dispatch) plus its source. Slices are borrowed —
/// callers pass `@embedFile`d or otherwise static strings, which is why
/// registration needs no allocator.
const RegisteredScript = struct {
    name: []const u8,
    source: [:0]const u8,
};

/// Fixed registration capacity. Scripts are registered once at boot by
/// generated code, so a hard cap with a loud panic beats dragging an
/// allocator into the plugin for a list that never grows past a few dozen.
const MAX_REGISTERED_SCRIPTS = 128;

// Module-level state, deliberately: a VM is a process-wide singleton (the
// contract symbols it binds are process-global too), and unlike ECS-backed
// plugins there is no game world to stash state in — the plugin can't even
// name the game's types. One game process, one VM, module scope.
var script_registry: [MAX_REGISTERED_SCRIPTS]RegisteredScript = undefined;
var script_count: usize = 0;
var active_vm: ?Backend.vm.Vm = null;

/// Register a script for the next `Controller.setup`. `name` is the
/// script's identity: error tracebacks read "<name>:<line>", and hook
/// dispatch is per-name. Registering an existing name REPLACES its source
/// (idempotent re-registration; also the future hot-reload seam).
///
/// v1 delivery model: the generated game calls this at boot with
/// `@embedFile`d sources from the project's `lua/` dir (the embedding
/// integration is a follow-up ticket — this function is the seam).
/// Registration after `setup` takes effect on the next setup.
pub fn registerScript(name: []const u8, source: [:0]const u8) void {
    for (script_registry[0..script_count]) |*s| {
        if (std.mem.eql(u8, s.name, name)) {
            s.source = source;
            return;
        }
    }
    if (script_count >= MAX_REGISTERED_SCRIPTS)
        @panic("labelle-scripting: script registry full — raise MAX_REGISTERED_SCRIPTS");
    script_registry[script_count] = .{ .name = name, .source = source };
    script_count += 1;
}

/// Number of currently registered scripts (introspection/tests).
pub fn registeredScriptCount() usize {
    return script_count;
}

/// Test seam: monotonic count of the language backend's scratch-buffer
/// (re)allocations. The scratch is grow-only, so a settled workload —
/// however many polls/gets — must stop bumping this; tests assert on
/// deltas across traffic, not absolute values.
pub fn scratchGrowthCount() usize {
    return Backend.bindings.scratch_growth_count;
}

/// Drop every registration. A test/tooling seam: production games register
/// once per process and never unregister (sources are static anyway).
pub fn clearScripts() void {
    script_count = 0;
}

// ── Console eval (labelle-scripting#4) ──────────────────────────────────
//
// The studio Script Console dispatches `{plugin: "scripting", command:
// "eval", params: {code}}` through the engine's editor-plugin-command
// channel; the pack hook shim (packs/scripting_console/hooks/
// console_eval.zig — compiled only inside generated games) routes it to
// `handleEvalCommand` below. The eval CORE lives here + in each
// backend's `Vm.evalConsole` so it is fully covered by this repo's
// mock-world suites with zero engine coupling.
//
// Buffer model: like the VM itself, eval state is module-level and
// main-thread-only — one rendered-text buffer, one params scratch. A
// result slice is valid until the next eval.

/// Rendered result/error text of the most recent eval.
var eval_text_buf: [eval.max_text_len]u8 = undefined;
/// Backs `eval.extractCode`'s params parse (json nesting stack + the
/// unescaped code). 2× the code cap always suffices.
var eval_params_scratch: [eval.max_code_len * 2]u8 = undefined;

/// The full studio-command path, shaped for the hook shim: decode
/// `params_json` (`{"code": "..."}`), evaluate in the active language
/// VM's persistent console environment, and build the bounded response
/// JSON (`{"ok":true,"value":…}` / `{"ok":false,"error":…}`) into `out`.
/// Callers pass a response-cap-sized buffer (the engine channel's
/// `max_response_len`); the returned slice points into `out`.
pub fn handleEvalCommand(params_json: []const u8, out: []u8) []const u8 {
    const code = eval.extractCode(params_json, &eval_params_scratch) orelse
        return eval.buildResponse(false, "invalid eval params — expected {\"code\":\"…\"}", out);
    const result = Controller.evalCommand(code);
    return eval.buildResponse(result.ok, result.text, out);
}

/// The plugin controller (assembler-wired):
///   setup  → boot the VM, install bindings + prelude, load registered
///            scripts, run each script's `init()`;
///   tick   → stamp dt, drain the event inbox, run each `update(dt)`;
///   deinit → run each `deinit()`, close the VM.
pub const Controller = struct {
    /// Boot the scripting VM. Refuses a Script Runtime Contract version
    /// mismatch (fail loudly at boot, not as garbled JSON mid-game) and a
    /// broken prelude. Individual scripts that fail to load or whose
    /// `init()` throws are logged and EVICTED — one bad script must not
    /// brick the game, the rest keep running, and a half-initialized
    /// script never receives `update`/`deinit` hooks (registrations
    /// survive, so the next setup retries it).
    pub fn setup(game: anytype) !void {
        _ = game; // world access rides the C contract, not Zig types
        if (active_vm != null) deinit(); // defensive: re-setup = clean restart

        const host_version = contract.labelle_contract_version();
        if (host_version != contract.SUPPORTED_CONTRACT_VERSION) {
            logHost("contract version mismatch: host exports a version this plugin does not support");
            return error.ContractVersionMismatch;
        }

        const vm = try Backend.vm.Vm.init();
        errdefer vm.close();
        try Backend.bindings.install(vm);
        active_vm = vm;

        // Two passes — load everything, then init everything — so an
        // early script's init() can already touch entities/events involving
        // scripts registered after it.
        for (script_registry[0..script_count]) |s| {
            // Load failures self-evict inside loadScript: a chunk body that
            // errors is pulled back out of the hook registry.
            _ = vm.loadScript(s.name, s.source);
        }
        for (script_registry[0..script_count]) |s| {
            if (!vm.callScriptHook(s.name, "init", null)) {
                // init() raised: the script is half-initialized — evict it
                // so update/deinit never run against broken state (the
                // init-time counterpart of loadScript's self-eviction).
                vm.evictScript(s.name);
            }
        }

        // Backends with a controller tier (ruby) instantiate + set up the
        // registered controller classes now, after every script's init —
        // scripts loaded and initialized first, structure on top. For
        // backends without the prelude function (lua) this is a no-op.
        vm.callLabelleFn("__setup_controllers", null);
    }

    /// Advance every script by one frame. Order per frame:
    ///   1. stamp `dt` into the host so `labelle.time_dt()` answers with
    ///      the same scaled dt Zig scripts received this tick;
    ///   2. drain the event inbox (handlers see last frame's events before
    ///      any update logic);
    ///   3. each script's `update(dt)`, registration order;
    ///   4. controller `tick(dt)`s, registration order (backends with a
    ///      controller tier — a no-op for the rest).
    /// Script errors are logged with a full traceback and never abort the
    /// tick — the remaining scripts still run. No-op before setup.
    pub fn tick(game: anytype, dt: f32) void {
        _ = game;
        const vm = active_vm orelse return;
        contract.labelle_time_dt_stamp(dt);
        vm.callLabelleFn("dispatch_inbox", null);
        for (script_registry[0..script_count]) |s| {
            // Update errors are logged per-call and do NOT evict — unlike a
            // failed init, the script's state is intact and the author gets
            // a traceback every tick until it's fixed.
            _ = vm.callScriptHook(s.name, "update", dt);
        }
        vm.callLabelleFn("__tick_controllers", dt);
    }

    /// Evaluate one console `code` string in the ACTIVE language VM
    /// (labelle-scripting#4 — the studio Script Console's eval core).
    ///
    /// Every backend gives the console a PERSISTENT environment that
    /// inherits the full labelle script API, so `x = 5` on one eval and
    /// `x` on the next behave like a REPL session: lua uses a dedicated
    /// registry-kept `_ENV` (`__index = _G`), ruby a reused compile
    /// context (mruby's mirb-style top-level locals keep), typescript
    /// the shared globals of QuickJS global-mode eval.
    ///
    /// Standard error isolation: an eval that throws NEVER kills the VM
    /// or the tick — the error text (message + traceback, each
    /// language's own machinery) comes back in `EvalResult.text` with
    /// `ok = false`, and the next eval / next tick proceed untouched.
    ///
    /// `text` is a bounded render (result value via the language's
    /// inspect/tostring, `eval.max_text_len` cap, truncation-marked) in
    /// a module buffer — valid until the next eval, main thread only.
    pub fn evalCommand(code: []const u8) eval.EvalResult {
        const vm = active_vm orelse return .{
            .ok = false,
            .text = "scripting VM is not running (eval before setup or after deinit)",
        };
        return vm.evalConsole(code, &eval_text_buf);
    }

    /// Teardown, LIFO against setup: controller `teardown`s in reverse
    /// registration order (where the backend has controllers), then each
    /// script's `deinit()` (registration order), then close the VM — the
    /// language's GC releases everything else. Idempotent; registrations
    /// survive (they're process-lifetime; see `registerScript`).
    pub fn deinit() void {
        const vm = active_vm orelse return;
        vm.callLabelleFn("__teardown_controllers", null);
        for (script_registry[0..script_count]) |s| {
            _ = vm.callScriptHook(s.name, "deinit", null);
        }
        vm.close();
        active_vm = null;
    }
};

/// Route a plugin-level (not script-level) message through the host log.
fn logHost(msg: []const u8) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("[scripting] {s}", .{msg}) catch {};
    const line = w.buffered();
    contract.labelle_log(line.ptr, line.len);
}
