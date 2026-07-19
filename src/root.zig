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
//! `-Dlanguage=ruby`, `-Dlanguage=typescript`, `-Dlanguage=rust`,
//! `-Dlanguage=crystal` or `-Dlanguage=csharp`) and surfaces the choice
//! through the `scripting_options` module; the comptime switch below is
//! what keeps unselected backends out of analysis entirely. Each backend
//! directory (src/lua/, src/ruby/, src/ts/, src/rust/, …) exposes the same
//! tiny surface: `vm.Vm`
//! (init/close/loadScript/callScriptHook/evictScript/callLabelleFn) and
//! `bindings.install`.
//!
//! Two integration FAMILIES share that surface (RFC-LANGUAGE-PLUGINS):
//! embedded-VM backends (lua/ruby/typescript) run sources delivered via
//! `registerScript`; the compiled backends (rust — src/rust/vm.zig,
//! crystal — src/crystal/vm.zig, csharp — src/csharp/vm.zig) are thin
//! dispatchers onto entry points of a compiled artifact (cargo staticlib /
//! crystal object linked into the game, or — for csharp — a managed
//! assembly the embedded CoreCLR runtime loads at runtime through
//! hostfxr), and registered sources are refused (compiled code can't run
//! from text). The Controller below is family-agnostic on purpose.

const std = @import("std");
const build_options = @import("scripting_options");

pub const contract = @import("contract.zig");

/// Console-eval shared pieces (labelle-scripting#4): result shape, params
/// decoding, bounded response-JSON builder. Engine-free — see
/// `Controller.evalCommand` / `handleEvalCommand` below for the seams.
pub const eval = @import("eval.zig");

/// Dev-mode disk watcher (labelle-engine#740) — the VM-free polling
/// layer behind `hot_reload` below. Re-exported so the test suites
/// exercise it directly against plain temp dirs.
pub const watch = @import("watch.zig");

/// Whether the mod sandbox profile is active (labelle-engine#740) —
/// resolved comptime from the project's plugin params; see
/// src/sandbox.zig for the per-language mechanism notes.
pub const sandbox_enabled = @import("sandbox.zig").enabled;

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
    .rust => struct {
        pub const vm = @import("rust/vm.zig");
        pub const bindings = @import("rust/bindings.zig");
    },
    .crystal => struct {
        pub const vm = @import("crystal/vm.zig");
        pub const bindings = @import("crystal/bindings.zig");
    },
    .csharp => struct {
        pub const vm = @import("csharp/vm.zig");
        pub const bindings = @import("csharp/bindings.zig");
    },
};

/// One registered script: a stable name (chunkname for error reporting,
/// registry key for hook dispatch) plus its source. Slices are borrowed —
/// callers pass `@embedFile`d or otherwise static strings, which is why
/// registration needs no allocator (the hot-reload glue below is the one
/// caller that swaps in heap sources, and it owns their lifetime).
const RegisteredScript = struct {
    name: []const u8,
    source: [:0]const u8,
    /// Load AND init both succeeded in the CURRENT VM — the reload seam's
    /// "does init still owe a run?" answer (a script broken at boot gets
    /// its init when a reload finally fixes it; a running script does NOT
    /// re-init on reload — its init-time entities would duplicate).
    initialized: bool = false,
    /// Error-UX throttle state (see `Controller.tick`): how many update()
    /// calls in a row have raised, and how many upcoming ticks to skip.
    consecutive_update_failures: u16 = 0,
    throttle_skip: u16 = 0,
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
    _ = findOrRegister(name, source);
}

/// Shared registration body for `registerScript` and `reloadScript`:
/// find-by-name (replacing the source) or append. Returns the registry
/// entry.
fn findOrRegister(name: []const u8, source: [:0]const u8) *RegisteredScript {
    for (script_registry[0..script_count]) |*s| {
        if (std.mem.eql(u8, s.name, name)) {
            s.source = source;
            return s;
        }
    }
    if (script_count >= MAX_REGISTERED_SCRIPTS)
        @panic("labelle-scripting: script registry full — raise MAX_REGISTERED_SCRIPTS");
    script_registry[script_count] = .{ .name = name, .source = source };
    script_count += 1;
    return &script_registry[script_count - 1];
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

// ── Hot reload (labelle-engine#740) ─────────────────────────────────────

/// Whether the ACTIVE backend can re-load a script into a running VM —
/// the VM family (lua/ruby/typescript) can re-eval; the native family
/// (rust/crystal/csharp) is compiled into/beside the game binary and is
/// explicitly OUT of hot-reload scope in v1 (a dev-mode dylib swap is
/// the RFC's sketched future, not this ticket).
pub const supports_reload = @hasDecl(Backend.vm.Vm, "reloadScript");

/// Reload one script: replace (or add) its registration and — when a VM
/// is running — re-load it in place. THE hot-push seam: the disk watcher
/// below feeds it, and the studio preview's hot-push integration will
/// call exactly this once the studio side grows the channel (there is no
/// engine hot-push contract to wire to yet — see the PR notes).
///
/// State semantics (per RFC-LANGUAGE-PLUGINS: "authoritative state lives
/// in components; ivars are caches — hot reload resets the VM"):
/// component/ECS data survives by construction (it lives in the host);
/// script-LOCAL state resets — the changed file's body re-runs in the
/// existing VM under each language's own semantics:
///   - lua: a FRESH private `_ENV` replaces the script's env (top-level
///     locals/globals reset); shared globals and the prelude survive;
///   - ruby: the previous incarnation is evicted first (harvested hooks,
///     handlers, controllers, the @ivar receiver), then the new body
///     runs and is re-harvested; controllers the new body registers are
///     instantiated + set up immediately;
///   - typescript: a fresh ES-module instance replaces the registry
///     namespace entry (module-scope state resets).
/// In every language the script's OLD event handlers are purged before
/// the new body registers its own — no duplicate-handler pileup.
///
/// `init()` policy: a script that was already running does NOT re-run
/// init (its init-time entities would duplicate); a script that never
/// completed load+init (broken at boot, now fixed) gets its init now —
/// the fix-and-save loop fully starts it. Update-throttle state resets
/// either way.
///
/// `name`/`source` lifetimes follow `registerScript` (borrowed, must
/// outlive the registry); returns false when the re-load or owed init
/// failed (logged through the host, VM untouched otherwise) or when the
/// backend has no reload story.
pub fn reloadScript(name: []const u8, source: [:0]const u8) bool {
    if (comptime !supports_reload) {
        // Refused OUTRIGHT (no registration either): the native backends
        // refuse registered sources wholesale — pretending to accept one
        // here would just defer the confusion to the next setup.
        logHost("hot reload is not supported for the native language family (rust/crystal/csharp) — restart the game");
        return false;
    } else {
        const entry = findOrRegister(name, source);
        entry.consecutive_update_failures = 0;
        entry.throttle_skip = 0;
        const vm = active_vm orelse return true; // next setup picks it up
        if (!vm.reloadScript(entry.name, entry.source)) {
            // The new body failed to load: the backend evicted whatever
            // it managed to register, so nothing half-new keeps running.
            // The registration keeps the new source — the author's next
            // save retries it.
            entry.initialized = false;
            return false;
        }
        if (!entry.initialized) {
            if (vm.callScriptHook(entry.name, "init", null)) {
                entry.initialized = true;
            } else {
                vm.evictScript(entry.name);
                return false;
            }
        }
        return true;
    }
}

/// Dev-mode disk watching (labelle-engine#740): poll the game's script
/// dir off the Controller tick and feed changed files through
/// `reloadScript`. COMPILED OUT unless the plugin is built with
/// `-Dhot_reload=true` (the dev-mode gate — the assembler's dev builds
/// will pass it; release builds never carry the watcher or its tick
/// branch). VM family only — `watchDir` refuses on native backends.
pub const hot_reload = struct {
    /// Poll cadence in Controller ticks (~4 Hz at 60 fps). Tick-counted,
    /// not wall-clocked, on purpose: Zig 0.16 has no std.time.Timer and
    /// a dev loop doesn't need one.
    pub const poll_interval_ticks: u32 = 15;

    /// Cap on one reloaded script file (dev-mode read guard).
    pub const max_script_bytes: usize = 1 << 20;

    var watcher: ?watch.Watcher = null;
    var gpa: std.mem.Allocator = undefined;
    var countdown: u32 = 0;

    /// Reload-owned sources + stable name storage: registry `name`
    /// slices must outlive the watcher (watcher entry storage reshuffles
    /// across polls), and re-read sources are heap copies that must be
    /// freed when the NEXT reload of the same script replaces them.
    const Owned = struct {
        name_buf: [watch.filename_cap]u8 = undefined,
        name_len: usize = 0,
        source: ?[:0]u8 = null,
    };
    var owned: [MAX_REGISTERED_SCRIPTS]Owned = @splat(.{});
    var owned_count: usize = 0;

    /// Start watching `dir_path` (resolved against the cwd) for the
    /// selected language's script files. `io`/`allocator` are stored for
    /// the polls; call from the game's main after Controller.setup (a
    /// generated dev build's splice, or by hand).
    pub fn watchDir(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) error{ HotReloadUnsupported, WatchDirOpen }!void {
        const dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
            return error.WatchDirOpen;
        return watchOpenedDir(io, allocator, dir);
    }

    /// `watchDir` over an already-open handle (must have `.iterate`
    /// capability). The watcher borrows it until `stopWatching`.
    pub fn watchOpenedDir(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) error{HotReloadUnsupported}!void {
        const ext = comptime scriptExtension() orelse return error.HotReloadUnsupported;
        watcher = watch.Watcher.init(io, dir, ext);
        gpa = allocator;
        countdown = 0;
    }

    /// Stop polling. The watched dir handle is the caller's to close;
    /// already-reloaded sources stay live (the registry points at them).
    pub fn stopWatching() void {
        watcher = null;
    }

    /// Poll now and reload every changed script; returns how many
    /// reloaded clean. Public so tests (and a future studio push) can
    /// force a deterministic poll; the tick path calls it on the
    /// `poll_interval_ticks` cadence.
    pub fn pump() usize {
        const w = if (watcher) |*ptr| ptr else return 0;
        var changes: [16]watch.Change = undefined;
        var reloaded: usize = 0;
        const n = w.poll(&changes);
        for (changes[0..n]) |ch| {
            const source = w.dir.readFileAllocOptions(
                w.io,
                ch.file,
                gpa,
                .limited(max_script_bytes),
                .of(u8),
                0,
            ) catch {
                logHost("hot reload: failed to read a changed script file — skipped");
                continue;
            };
            if (reloadOwned(ch.name, source)) reloaded += 1;
        }
        return reloaded;
    }

    /// Called from Controller.tick (comptime-gated there).
    fn pumpTick() void {
        if (watcher == null) return;
        if (countdown > 0) {
            countdown -= 1;
            return;
        }
        countdown = poll_interval_ticks - 1;
        _ = pump();
    }

    /// Route one freshly read source through `reloadScript`, managing
    /// ownership: the registry gets slot-stable name storage and the
    /// slot's previous heap source is freed once replaced.
    fn reloadOwned(name: []const u8, source: [:0]u8) bool {
        const slot = ownedSlot(name) orelse {
            gpa.free(source);
            logHost("hot reload: too many watched scripts — raise MAX_REGISTERED_SCRIPTS");
            return false;
        };
        const prev = slot.source;
        slot.source = source;
        const ok = reloadScript(slot.name_buf[0..slot.name_len], source);
        if (prev) |p| gpa.free(p); // registry now points at `source`
        return ok;
    }

    fn ownedSlot(name: []const u8) ?*Owned {
        for (owned[0..owned_count]) |*slot| {
            if (std.mem.eql(u8, slot.name_buf[0..slot.name_len], name)) return slot;
        }
        if (owned_count >= owned.len or name.len > watch.filename_cap) return null;
        const slot = &owned[owned_count];
        owned_count += 1;
        @memcpy(slot.name_buf[0..name.len], name);
        slot.name_len = name.len;
        slot.source = null;
        return slot;
    }

    /// Test/tooling seam: stop watching and free every reload-owned
    /// source. Callers must have cleared the registry (or torn the VM
    /// down and re-registered) first — registry entries may point at the
    /// freed sources.
    pub fn reset() void {
        stopWatching();
        for (owned[0..owned_count]) |*slot| {
            if (slot.source) |s| gpa.free(s);
            slot.source = null;
        }
        owned_count = 0;
    }

    fn scriptExtension() ?[]const u8 {
        return switch (build_options.language) {
            .lua => ".lua",
            .ruby => ".rb",
            // The VM evaluates JS; in a generated dev build the watch
            // dir is the assembler's transpile OUTPUT (tsc --watch or a
            // dev-mode transpile step keeps it fresh) — watching raw
            // .ts would need an in-process transpiler this plugin
            // deliberately doesn't carry.
            .typescript => ".js",
            else => null, // native family — no VM to re-load into
        };
    }
};

// ── Error-UX throttle policy (labelle-engine#740) ───────────────────────

/// After this many CONSECUTIVE update() failures of one script, its
/// update stops running every tick…
pub const update_throttle_threshold: u16 = 3;

/// …and is attempted (and its traceback logged) only once every this
/// many ticks — one line a second at 60 fps instead of sixty — until an
/// attempt succeeds, which restores full cadence immediately. Init/load
/// failures don't need this (they evict); event-handler and controller
/// errors are event-cadence, not 60/s, and stay unthrottled.
pub const update_throttle_stride: u16 = 60;

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
///
/// ## The dispatch contract (labelle-scripting#3 — pinned; coordinate
/// before changing)
///
/// The assembler's scripting splice (labelle-assembler#596) drives this
/// Controller EXPLICITLY: generated mains call `setup` from the plugin
/// block, emit `scripting.Controller.tick(&g, scaled_dt)` inside the
/// frame loop, and arity-dispatch `deinit` as ZERO-ARG. Two consequences
/// this module must honor until a coordinated assembler release says
/// otherwise (tests/root.zig pins both, in every language binary):
///
///   - NO `Systems` decl, ever, on this module or the Controller: the
///     engine auto-ticks plugin `Systems`, so growing one would DOUBLE-
///     TICK the VM in every generated game. Explicit-tick-only is the
///     contract, not a v0.1 accident.
///   - `deinit` stays zero-parameter: the generated PluginControllers
///     deinit block selects the zero-arg arm by arity.
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
        // scripts registered after it. Per-entry `initialized` records
        // load+init success for the reload seam (a boot-broken script owes
        // an init when a reload fixes it); throttle state starts clean in
        // every fresh VM.
        var loaded: [MAX_REGISTERED_SCRIPTS]bool = undefined;
        for (script_registry[0..script_count], 0..) |*s, i| {
            s.initialized = false;
            s.consecutive_update_failures = 0;
            s.throttle_skip = 0;
            // Load failures self-evict inside loadScript: a chunk body that
            // errors is pulled back out of the hook registry.
            loaded[i] = vm.loadScript(s.name, s.source);
        }
        for (script_registry[0..script_count], 0..) |*s, i| {
            if (!loaded[i]) continue;
            if (vm.callScriptHook(s.name, "init", null)) {
                s.initialized = true;
            } else {
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
    /// tick — the remaining scripts still run, with repeat offenders
    /// throttled (see `update_throttle_threshold`/`_stride`: after 3
    /// consecutive update() failures the script is attempted — and its
    /// traceback logged — only once every 60 ticks until an attempt
    /// succeeds, which restores full cadence). No-op before setup.
    ///
    /// Dev builds (`-Dhot_reload=true`) also pump the disk watcher here,
    /// at tick START so reloaded code runs the very tick it lands.
    pub fn tick(game: anytype, dt: f32) void {
        _ = game;
        const vm = active_vm orelse return;
        if (comptime build_options.hot_reload) hot_reload.pumpTick();
        contract.labelle_time_dt_stamp(dt);
        vm.callLabelleFn("dispatch_inbox", null);
        for (script_registry[0..script_count]) |*s| {
            if (s.throttle_skip > 0) {
                s.throttle_skip -= 1;
                continue;
            }
            // Update errors are logged per-call and do NOT evict — unlike a
            // failed init, the script's state is intact and the author gets
            // a traceback (at full cadence until the throttle kicks in).
            if (vm.callScriptHook(s.name, "update", dt)) {
                s.consecutive_update_failures = 0;
            } else {
                s.consecutive_update_failures +|= 1;
                if (s.consecutive_update_failures == update_throttle_threshold)
                    logThrottled(s.name);
                if (s.consecutive_update_failures >= update_throttle_threshold)
                    s.throttle_skip = update_throttle_stride - 1;
            }
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

/// Announce (once per failure episode) that a script's update() hit the
/// consecutive-failure threshold and is being throttled.
fn logThrottled(script_name: []const u8) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(
        "[scripting] {s}: update() failed {d} ticks in a row — throttling to one attempt every {d} ticks until it succeeds",
        .{ script_name, update_throttle_threshold, update_throttle_stride },
    ) catch {};
    const line = w.buffered();
    contract.labelle_log(line.ptr, line.len);
}

/// Route a plugin-level (not script-level) message through the host log.
fn logHost(msg: []const u8) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("[scripting] {s}", .{msg}) catch {};
    const line = w.buffered();
    contract.labelle_log(line.ptr, line.len);
}
