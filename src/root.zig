//! labelle-scripting — script labelle games in non-Zig languages.
//!
//! This module is the SHARED plugin glue: the plugin `Controller`
//! (RFC-plugin-controllers shape — `setup`/`tick`/`deinit`, wired by the
//! assembler like any other plugin) plus `registerScript`, the seam the
//! generated game feeds embedded script sources through. Everything
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
//! Language sub-modules: build.zig selects exactly one (`-Dlanguage=lua`)
//! and surfaces the choice through the `scripting_options` module; the
//! comptime switch below is what keeps unselected backends out of
//! analysis entirely. Each backend directory (src/lua/, later src/js/, …)
//! exposes the same tiny surface: `vm.Vm` (init/close/loadScript/
//! callScriptHook/evictScript/callLabelleFn) and `bindings.install`.

const std = @import("std");
const build_options = @import("scripting_options");

pub const contract = @import("contract.zig");

/// The active language backend, resolved at comptime from the build
/// option. Adding a language = new `src/<lang>/` + one arm here.
const Backend = switch (build_options.language) {
    .lua => struct {
        pub const vm = @import("lua/vm.zig");
        pub const bindings = @import("lua/bindings.zig");
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
    }

    /// Advance every script by one frame. Order per frame:
    ///   1. stamp `dt` into the host so `labelle.time_dt()` answers with
    ///      the same scaled dt Zig scripts received this tick;
    ///   2. drain the event inbox (handlers see last frame's events before
    ///      any update logic);
    ///   3. each script's `update(dt)`, registration order.
    /// Script errors are logged with a full traceback and never abort the
    /// tick — the remaining scripts still run. No-op before setup.
    pub fn tick(game: anytype, dt: f32) void {
        _ = game;
        const vm = active_vm orelse return;
        contract.labelle_time_dt_stamp(dt);
        vm.callLabelleFn("dispatch_inbox");
        for (script_registry[0..script_count]) |s| {
            // Update errors are logged per-call and do NOT evict — unlike a
            // failed init, the script's state is intact and the author gets
            // a traceback every tick until it's fixed.
            _ = vm.callScriptHook(s.name, "update", dt);
        }
    }

    /// Run each script's `deinit()` (registration order), then close the
    /// VM — Lua's GC releases everything else. Idempotent; registrations
    /// survive (they're process-lifetime; see `registerScript`).
    pub fn deinit() void {
        const vm = active_vm orelse return;
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
