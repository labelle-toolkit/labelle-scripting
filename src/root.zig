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
//! `-Dlanguage=crystal`, `-Dlanguage=csharp` or `-Dlanguage=go`) and
//! surfaces the choice
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
//! crystal — src/crystal/vm.zig, csharp — src/csharp/vm.zig, go —
//! src/go/vm.zig) are thin
//! dispatchers onto entry points of a compiled artifact (cargo staticlib /
//! crystal object / go c-archive linked into the game, or — for csharp — a managed
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
    .go => struct {
        pub const vm = @import("go/vm.zig");
        pub const bindings = @import("go/bindings.zig");
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
/// (rust/crystal/csharp/go) is compiled into/beside the game binary and is
/// explicitly OUT of hot-reload scope in v1 (a dev-mode dylib swap is
/// the RFC's sketched future, not this ticket).
pub const supports_reload = @hasDecl(Backend.vm.Vm, "reloadScript");

/// Reload one script: replace (or add) its registration and — when a VM
/// is running — re-load it in place. THE hot-push seam: the disk watcher
/// below feeds it, and the studio preview's hot-push integration will
/// call exactly this once the studio side grows the channel (there is no
/// engine hot-push contract to wire to yet — see the PR notes).
///
/// ## The reload lifecycle (one rule, every VM language)
///
/// A successful reload REPLAYS the script's whole load lifecycle in the
/// running VM: evict the old incarnation (its event handlers, and on
/// ruby its controllers, are purged) → run the new body → **re-run
/// `init()`** → (ruby) set up the controllers the new body registered.
/// Re-running init is the dev-mode contract: init-registered
/// subscriptions come back (no silent subscription loss — init is a
/// documented place to call `labelle.on`), and script-local state resets
/// wholesale (per RFC-LANGUAGE-PLUGINS: "authoritative state lives in
/// components; ivars are caches — hot reload resets the VM"). The
/// deliberate, documented caveat: NON-IDEMPOTENT init side effects
/// re-apply — an init that unconditionally spawns entities spawns them
/// again on every save. Write idempotent init (probe before spawning)
/// or accept re-runs under hot reload; component/ECS data itself
/// survives by construction (it lives in the host, untouched).
///
/// Per-language reset shape (same contract, each VM's own semantics):
///   - lua: a FRESH private `_ENV` replaces the script's env (top-level
///     locals/globals reset); shared globals and the prelude survive;
///   - ruby: the previous incarnation is evicted first (harvested hooks,
///     handlers, controllers, the @ivar receiver), the new body runs and
///     is re-harvested, and AFTER init its controllers are instantiated
///     + set up (`finishReload` — init-seeded state exists first, the
///     boot order);
///   - typescript: a fresh ES-module instance replaces the registry
///     namespace entry (module-scope state resets).
///
/// ## Failure states
///
/// A save whose body fails (syntax or runtime error) leaves the script
/// SILENT — env/namespace removed, handlers purged, update/deinit skip
/// it — until the next save fixes it (running half-old code with its
/// handlers purged would be worse than running none). The next
/// successful save replays the full lifecycle above, exactly like any
/// other reload — there is no separate "owed init" state to track. An
/// init() that raises on reload evicts the same way. Update-throttle
/// state resets on every reload.
///
/// `name`/`source` lifetimes follow `registerScript` (borrowed, must
/// outlive the registry); returns false when the re-load or the re-init
/// failed (logged through the host, VM otherwise untouched) or when the
/// backend has no reload story.
pub fn reloadScript(name: []const u8, source: [:0]const u8) bool {
    if (comptime !supports_reload) {
        // Refused OUTRIGHT (no registration either): the native backends
        // refuse registered sources wholesale — pretending to accept one
        // here would just defer the confusion to the next setup.
        logHost("hot reload is not supported for the native language family (rust/crystal/csharp/go) — restart the game");
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
            return false;
        }
        // Replay init — the reload lifecycle above. A missing init hook
        // is fine (callScriptHook: missing = not a failure).
        if (!vm.callScriptHook(entry.name, "init", null)) {
            vm.evictScript(entry.name);
            return false;
        }
        // Backend post-init reload step (ruby: instantiate + set up the
        // controllers the fresh body registered — after init, the boot
        // order). Absent on backends without one.
        if (comptime @hasDecl(Backend.vm.Vm, "finishReload")) vm.finishReload(entry.name);
        return true;
    }
}

/// Dev-mode disk watching (labelle-engine#740): poll the game's script
/// dirs off the frame loop and feed changed files through
/// `reloadScript`. COMPILED OUT unless the plugin is built with
/// `-Dhot_reload=true` (the dev-mode gate — the assembler's dev builds
/// will pass it; release builds never carry the watcher or its tick
/// branch). VM family only — `watchDir` refuses on native backends.
///
/// MULTI-ROOT (labelle-scripting#51): the watch layer is a registry of
/// watched roots — the game's `scripts/` plus any local pack script dirs
/// (`packs/<pack>/scripts`) the assembler's dev splice registers.
/// `watchDir` ADDS a root (idempotent per CANONICAL path — re-registering
/// a dir that resolves to the same realpath, however spelled, restarts
/// that root's watcher instead of duplicating it); each root keeps its own
/// baseline, its own lossless-loop state, its own allocator, the per-root
/// registered-stem rule (`watch.stemOf` against the root's own entries),
/// and a reload-name PREFIX. The reload key is `<prefix><stem>`: the game
/// root's prefix is empty (stems reload bare, as always), while a pack
/// root registered via `watchDirNamed(dir, "sky__")` reloads its stems
/// under `sky__<stem>` — so two roots' same-stem scripts key onto their
/// own namespaced registrations and never alias.
pub const hot_reload = struct {
    /// Tick-pump cadence in Controller ticks (~4 Hz at 60 fps) — the
    /// legacy pump path (`Controller.tick`), kept for generated mains
    /// predating the `pumpFrame` splice.
    pub const poll_interval_ticks: u32 = 15;

    /// Wall-clock pump cadence for `pumpFrame` in milliseconds (~4 Hz).
    /// A var on purpose — tests shrink it to force immediate polls; the
    /// dev loop never touches it.
    pub var poll_interval_ms: i64 = 250;

    /// Cap on one reloaded script file (dev-mode read guard).
    pub const max_script_bytes: usize = 1 << 20;

    /// Watched-root capacity: the game's script dir + a handful of local
    /// pack script dirs. Registration past this cap errors loudly
    /// (`error.TooManyWatchRoots`) — dev-mode wiring degrades, the game
    /// keeps running.
    pub const max_watch_roots = 8;

    /// Longest canonical root path that keeps its idempotency identity.
    /// Longer paths still watch fine — they just re-register as new
    /// roots instead of replacing (bounded storage, no allocator).
    pub const max_root_path = 512;

    /// Longest per-root reload-name prefix (a pack namespace, `sky__`).
    /// A longer prefix is refused (`error.WatchDirPrefixTooLong`) — dev
    /// wiring degrades rather than truncate a namespace into a mismatch.
    pub const max_name_prefix = 64;

    /// Stack scratch cap for BUILDING a reload key (`<prefix><stem>`)
    /// before it is looked up. Sized for the widest possible prefix +
    /// stem; a key that overflows the STORED cap below is dropped by
    /// `ownedSlot`, never truncated. This is a stack buffer only — it is
    /// deliberately NOT the `Owned.name_buf` size, so the reload-owned
    /// registry keeps its pre-#51 static footprint (a bigger static
    /// `owned` array shifts BSS layout, which surfaced a latent
    /// mruby-on-Linux alignment crash in the declare-tool suite that
    /// shares this binary — the watcher itself is heap-clean under Guard
    /// Malloc).
    pub const reload_name_build_cap = watch.filename_cap + max_name_prefix;

    /// Longest STORED/looked-up reload key. Kept at the pre-#51
    /// `filename_cap` so `Owned.name_buf` (× `MAX_REGISTERED_SCRIPTS`)
    /// does not grow: a `<prefix><stem>` longer than this is dropped
    /// (logged), never stored. A `sky__`-class prefix + any real stem
    /// fits comfortably.
    pub const max_reload_name = watch.filename_cap;

    /// One watched root: the poller, the CANONICAL path identity (realpath
    /// of the opened dir — empty for `watchOpenedDir` roots, which carry no
    /// path), the allocator to read/free THIS root's sources with, and the
    /// reload-name prefix every stem this root reports is registered under
    /// (empty for the game root — its stems register bare; `<pack>__` for a
    /// pack root, so two roots' same-stem scripts never alias, #51 round-2).
    const Root = struct {
        watcher: watch.Watcher,
        allocator: std.mem.Allocator,
        path_buf: [max_root_path]u8 = undefined,
        path_len: usize = 0,
        prefix_buf: [max_name_prefix]u8 = undefined,
        prefix_len: usize = 0,
        /// True when `watchDir` opened the handle here (so replacing or
        /// `stopWatching` may close it); `watchOpenedDir` handles are
        /// borrowed and stay the caller's to close.
        opened_here: bool = false,

        fn path(self: *const Root) []const u8 {
            return self.path_buf[0..self.path_len];
        }
        fn prefix(self: *const Root) []const u8 {
            return self.prefix_buf[0..self.prefix_len];
        }
    };

    var roots: [max_watch_roots]Root = undefined;
    var root_count: usize = 0;
    var countdown: u32 = 0;
    /// Wall-clock pump state (`pumpFrame`): the last poll's monotonic
    /// stamp, null until the first frame pump.
    var last_wall_poll: ?std.Io.Timestamp = null;

    /// Reload-owned sources + stable name storage: registry `name`
    /// slices must outlive the watcher (watcher entry storage reshuffles
    /// across polls), and re-read sources are heap copies that must be
    /// freed when the NEXT reload of the same script replaces them —
    /// with the SAME allocator that read them (roots may use different
    /// allocators, #51 round-2), so each slot remembers its own.
    const Owned = struct {
        name_buf: [watch.filename_cap]u8 = undefined,
        name_len: usize = 0,
        source: ?[:0]u8 = null,
        source_allocator: std.mem.Allocator = undefined,
    };
    var owned: [MAX_REGISTERED_SCRIPTS]Owned = @splat(.{});
    var owned_count: usize = 0;

    /// Number of currently watched roots (introspection/tests).
    pub fn watchedRootCount() usize {
        return root_count;
    }

    /// ADD `dir_path` (resolved against the cwd) to the watched roots for
    /// the selected language's script files. `io`/`allocator` are stored
    /// for the polls; call from the game's main after Controller.setup (a
    /// generated dev build's splice, or by hand) — once per root: the
    /// game's script dir, then each local pack script dir.
    ///
    /// Idempotent per CANONICAL path: re-registering a path that resolves
    /// (realpath) to an already-watched root REPLACES that root's watcher
    /// (fresh handle, re-primed baseline) instead of adding a duplicate
    /// that would double-report every edit — even when the two calls spell
    /// the same dir differently (`scripts` vs `./scripts` vs an absolute
    /// path, #51 round-2).
    pub fn watchDir(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) error{ HotReloadUnsupported, WatchDirOpen, TooManyWatchRoots, WatchDirPrefixTooLong }!void {
        return watchDirNamed(io, allocator, dir_path, "");
    }

    /// `watchDir` with a reload-name `prefix` (a pack namespace, `sky__`):
    /// every stem this root reports reloads under `<prefix><stem>`, so a
    /// pack whose scripts register namespaced reload against the right
    /// registration and never alias the game's same-stem scripts (#51
    /// round-2). Empty prefix = the game-root behavior (`watchDir`).
    pub fn watchDirNamed(
        io: std.Io,
        allocator: std.mem.Allocator,
        dir_path: []const u8,
        prefix: []const u8,
    ) error{ HotReloadUnsupported, WatchDirOpen, TooManyWatchRoots, WatchDirPrefixTooLong }!void {
        const ext = comptime scriptExtension() orelse return error.HotReloadUnsupported;
        if (prefix.len > max_name_prefix) return error.WatchDirPrefixTooLong;

        // Open FIRST, then take the canonical identity from the live
        // handle: two different spellings of the same dir resolve to one
        // realpath, so the dedup below catches them (a raw `mem.eql` on the
        // caller's string would not). Opening before the capacity check
        // means the overflow path must close the handle it just opened.
        const dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
            return error.WatchDirOpen;

        var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon: []const u8 = if (dir.realPath(io, &canon_buf)) |n|
            canon_buf[0..n]
        else |_|
            dir_path; // realpath failed (rare) — fall back to the raw spelling

        // Same-canonical → replace in place; else append. A non-empty
        // canonical path AND a non-empty stored path (a `watchOpenedDir`
        // root stores none) guard the full `mem.eql` — never a prefix,
        // never an empty-string match.
        var slot: ?*Root = null;
        if (canon.len > 0 and canon.len <= max_root_path) {
            for (roots[0..root_count]) |*r| {
                if (r.path_len > 0 and std.mem.eql(u8, r.path(), canon)) {
                    slot = r;
                    break;
                }
            }
        }
        if (slot == null and root_count >= max_watch_roots) {
            dir.close(io);
            return error.TooManyWatchRoots;
        }

        if (slot) |r| {
            // Replacement: close the previous handle with the io that
            // OPENED it (`r.watcher.io`, matching `stopWatching`). A
            // borrowed watchOpenedDir handle stores no path and can't
            // match here, so `opened_here` is always true.
            if (r.opened_here) r.watcher.dir.close(r.watcher.io);
            r.watcher = watch.Watcher.init(io, dir, ext);
            r.allocator = allocator;
            r.opened_here = true;
            setPrefix(r, prefix);
        } else {
            const r = &roots[root_count];
            r.* = .{ .watcher = watch.Watcher.init(io, dir, ext), .allocator = allocator, .opened_here = true };
            if (canon.len <= max_root_path) {
                @memcpy(r.path_buf[0..canon.len], canon);
                r.path_len = canon.len;
            }
            setPrefix(r, prefix);
            root_count += 1;
        }
        countdown = 0;
        // A newly-added root must poll PROMPTLY: reset the wall-clock
        // throttle so it isn't stuck behind the previous root's interval
        // (#51 round-2).
        last_wall_poll = null;
    }

    fn setPrefix(r: *Root, prefix: []const u8) void {
        @memcpy(r.prefix_buf[0..prefix.len], prefix);
        r.prefix_len = prefix.len;
    }

    /// `watchDir` over an already-open handle (must have `.iterate`
    /// capability). The watcher borrows it until `stopWatching` — the
    /// handle stays the caller's to close. ADDS a root like `watchDir`;
    /// an open handle has no path identity, so there is no idempotency
    /// here — don't register the same handle twice.
    pub fn watchOpenedDir(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) error{ HotReloadUnsupported, TooManyWatchRoots }!void {
        return watchOpenedDirNamed(io, allocator, dir, "") catch |err| switch (err) {
            error.WatchDirPrefixTooLong => unreachable, // empty prefix
            else => |e| return e,
        };
    }

    /// `watchOpenedDir` with a reload-name `prefix` (see `watchDirNamed`).
    pub fn watchOpenedDirNamed(
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        prefix: []const u8,
    ) error{ HotReloadUnsupported, TooManyWatchRoots, WatchDirPrefixTooLong }!void {
        const ext = comptime scriptExtension() orelse return error.HotReloadUnsupported;
        if (prefix.len > max_name_prefix) return error.WatchDirPrefixTooLong;
        if (root_count >= max_watch_roots) return error.TooManyWatchRoots;
        const r = &roots[root_count];
        r.* = .{ .watcher = watch.Watcher.init(io, dir, ext), .allocator = allocator };
        setPrefix(r, prefix);
        root_count += 1;
        countdown = 0;
        last_wall_poll = null;
    }

    /// Stop polling every root. Handles `watchDir` opened here are
    /// closed; `watchOpenedDir` handles are the caller's to close.
    /// Already-reloaded sources stay live (the registry points at them).
    pub fn stopWatching() void {
        for (roots[0..root_count]) |*r| {
            if (r.opened_here) r.watcher.dir.close(r.watcher.io);
        }
        root_count = 0;
        countdown = 0;
        last_wall_poll = null;
    }

    /// Poll every root now and reload every changed script; returns how
    /// many reloaded clean. Public so tests (and a future studio push)
    /// can force a deterministic poll; the cadence paths (`pumpTick`,
    /// `pumpFrame`) call it throttled. Roots are independent: one root's
    /// scan abort or read failure never stalls another's drain.
    pub fn pump() usize {
        var reloaded: usize = 0;
        for (roots[0..root_count]) |*r| reloaded += pumpRoot(r);
        return reloaded;
    }

    /// One root's lossless drain (the PR #47 loop, per root now). Reads
    /// and frees with the root's OWN allocator, and reloads each reported
    /// stem under the root's namespace prefix.
    fn pumpRoot(r: *Root) usize {
        const w = &r.watcher;
        var changes: [16]watch.Change = undefined;
        var reloaded: usize = 0;
        // Drain: a FULL batch means the watcher may be sitting on more
        // (its overflow defers unreported changes losslessly) — poll
        // again until a partial batch. Terminates: every reported change
        // commits its baseline, so each round strictly shrinks the
        // backlog (and a read failure ends the drain — see below).
        while (true) {
            const n = w.poll(&changes);
            var read_failed = false;
            for (changes[0..n]) |ch| {
                const source = readChanged(w, r.allocator, ch.file) orelse {
                    // The atomic-save race: the editor may still be
                    // writing the file this very moment. The watcher
                    // already committed the new baseline when it
                    // reported, so without intervention the edit would
                    // be LOST (next poll sees no diff) — mark the entry
                    // dirty so the next poll re-reports and the read
                    // retries. Same lossless principle as the overflow
                    // deferral.
                    w.markDirty(ch.file);
                    read_failed = true;
                    logHost("hot reload: failed to read a changed script file — will retry next poll");
                    continue;
                };
                // Reload key = the root's namespace prefix + the reported
                // stem, built in a stack scratch buffer. Empty prefix (game
                // root) → the bare stem, exactly as before; a pack root's
                // `<pack>__` prefix keys its reload onto the namespaced
                // registration and never aliases the game's same-stem
                // scripts (#51 round-2). An over-long key (a pathological
                // prefix+stem past the build cap) drops rather than reload
                // under a wrong (bare) name — `reloadOwned` is skipped and
                // the source freed here.
                var name_buf: [reload_name_build_cap]u8 = undefined;
                if (r.prefix_len + ch.name.len > name_buf.len) {
                    r.allocator.free(source);
                    logHost("hot reload: reload name too long — skipped");
                    continue;
                }
                @memcpy(name_buf[0..r.prefix_len], r.prefix());
                @memcpy(name_buf[r.prefix_len..][0..ch.name.len], ch.name);
                const name = name_buf[0 .. r.prefix_len + ch.name.len];
                if (reloadOwned(r.allocator, name, source)) reloaded += 1;
            }
            // A dirty-marked file would re-report IMMEDIATELY on the
            // next drain round — retry on the next cadence poll instead
            // (the write needs time to finish anyway) so a persistently
            // unreadable file can never spin this loop.
            if (read_failed or n < changes.len) break;
        }
        return reloaded;
    }

    /// Test seam: make `pump`'s next file read fail (exercises the
    /// retry-after-read-failure path without a fault-injecting fs).
    pub var debug_fail_next_read: bool = false;

    /// One changed file's bytes (sentinel-terminated), or null on any
    /// read failure — the injectable read behind `pump`. Reads with the
    /// root's own `allocator`.
    fn readChanged(w: *watch.Watcher, allocator: std.mem.Allocator, file: []const u8) ?[:0]u8 {
        if (debug_fail_next_read) {
            debug_fail_next_read = false;
            return null;
        }
        return w.dir.readFileAllocOptions(
            w.io,
            file,
            allocator,
            .limited(max_script_bytes),
            .of(u8),
            0,
        ) catch null;
    }

    /// Called from Controller.tick (comptime-gated there) — the LEGACY
    /// pump path, tick-counted. Kept because generated mains splice
    /// `Controller.tick` inside the frame loop's `scaled_dt > 0` gate:
    /// on assemblers predating the `pumpFrame` splice this is the only
    /// pump there is (and it pauses with the game — the #51 gap).
    fn pumpTick() void {
        if (root_count == 0) return;
        if (countdown > 0) {
            countdown -= 1;
            return;
        }
        countdown = poll_interval_ticks - 1;
        _ = pump();
    }

    /// The WALL-CLOCK pump (labelle-scripting#51): poll at most once per
    /// `poll_interval_ms` of REAL time, however often (or rarely) it is
    /// called. THE pre-timescale seam: generated dev mains call this
    /// every frame OUTSIDE the `scaled_dt > 0` gate — the generated
    /// frame loop skips `Controller.tick` entirely at `time_scale == 0`,
    /// so the tick-counted pump above freezes exactly when a developer
    /// pauses to edit. This one keeps reloading while paused. Safe
    /// beside `pumpTick` (older splices, or both emitted): each is
    /// throttled on its own cadence and `pump` itself is stat-cheap, so
    /// double-pumping is a few extra stats per second at worst.
    /// Returns how many scripts reloaded clean this call.
    pub fn pumpFrame() usize {
        if (root_count == 0) return 0;
        // Any root's io reaches the monotonic clock (`.awake` — macOS
        // CLOCK_UPTIME_RAW / Linux CLOCK_MONOTONIC via std.Io.Threaded).
        const io = roots[0].watcher.io;
        const now = std.Io.Timestamp.now(io, .awake);
        if (last_wall_poll) |prev| {
            if (prev.durationTo(now).toMilliseconds() < poll_interval_ms) return 0;
        }
        last_wall_poll = now;
        return pump();
    }

    /// Route one freshly read source through `reloadScript`, managing
    /// ownership: the registry gets slot-stable name storage and the
    /// slot's previous heap source is freed once replaced — each with
    /// the allocator that READ it (`source` was read with `allocator`;
    /// the previous source remembers its own on the slot, #51 round-2).
    fn reloadOwned(allocator: std.mem.Allocator, name: []const u8, source: [:0]u8) bool {
        const slot = ownedSlot(name) orelse {
            allocator.free(source);
            logHost("hot reload: too many watched scripts — raise MAX_REGISTERED_SCRIPTS");
            return false;
        };
        const prev = slot.source;
        const prev_allocator = slot.source_allocator;
        slot.source = source;
        slot.source_allocator = allocator;
        const ok = reloadScript(slot.name_buf[0..slot.name_len], source);
        if (prev) |p| prev_allocator.free(p); // registry now points at `source`
        return ok;
    }

    fn ownedSlot(name: []const u8) ?*Owned {
        for (owned[0..owned_count]) |*slot| {
            if (std.mem.eql(u8, slot.name_buf[0..slot.name_len], name)) return slot;
        }
        if (owned_count >= owned.len or name.len > max_reload_name) return null;
        const slot = &owned[owned_count];
        owned_count += 1;
        @memcpy(slot.name_buf[0..name.len], name);
        slot.name_len = name.len;
        slot.source = null;
        return slot;
    }

    /// Test/tooling seam: stop watching and free every reload-owned
    /// source (each with the allocator that read it). Callers must have
    /// cleared the registry (or torn the VM down and re-registered)
    /// first — registry entries may point at the freed sources.
    pub fn reset() void {
        stopWatching();
        for (owned[0..owned_count]) |*slot| {
            if (slot.source) |s| slot.source_allocator.free(s);
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
        // scripts registered after it. Throttle state starts clean in
        // every fresh VM.
        var loaded: [MAX_REGISTERED_SCRIPTS]bool = undefined;
        for (script_registry[0..script_count], 0..) |*s, i| {
            s.consecutive_update_failures = 0;
            s.throttle_skip = 0;
            // Load failures self-evict inside loadScript: a chunk body that
            // errors is pulled back out of the hook registry.
            loaded[i] = vm.loadScript(s.name, s.source);
        }
        for (script_registry[0..script_count], 0..) |*s, i| {
            if (!loaded[i]) continue;
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
