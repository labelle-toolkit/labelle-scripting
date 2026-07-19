//! The go sub-module's "VM" (labelle-engine#746, native-compiled
//! family, third language on the rust skeleton): there is no
//! interpreter — game scripts are compiled go, built by the plugin's
//! declared build step (`go build -buildmode=c-archive`, see
//! plugin.labelle `.language_builds`) into `liblabelle_go_scripts.a`
//! and LINKED into the game binary. This file adapts the shared
//! Controller's VM-shaped surface onto the glue's labelle_go_* entry
//! points, the exact labelle_rs_* twin:
//!
//!   Controller.setup   → Vm.init (labelle_go_abi_version handshake)
//!                        … registered-source loop: no-ops
//!                        → callLabelleFn("__setup_controllers")
//!                          = labelle_go_setup (game Register + Inits)
//!   Controller.tick    → callLabelleFn("dispatch_inbox")
//!                          = labelle_go_dispatch_inbox (event fan-out)
//!                        → callLabelleFn("__tick_controllers", dt)
//!                          = labelle_go_tick (every Update(dt))
//!   Controller.deinit  → callLabelleFn("__teardown_controllers")
//!                          = labelle_go_deinit (Deinits, LIFO)
//!                        → Vm.close (no-op)
//!
//! ## The guest runtime (the go-only fact — see native-go/labelle.go's
//! coexistence matrix for the full story)
//!
//! Unlike rust/crystal, go brings its WHOLE RUNTIME into the game
//! binary as a guest: the c-archive initializes it (scheduler, GC,
//! signal handlers) from a global constructor at process start — before
//! main(), before this file runs — so there is no boot leg to sequence
//! here (crystal's labelle_cr_boot has no go analog and nothing can be
//! poisoned). The runtime's threads never touch the contract; contract
//! calls happen synchronously inside the entry points below, on the
//! game's main thread, and the go side's hook guard panics pointedly on
//! the detectable misuse (a goroutine calling the labelle API between
//! frames).
//!
//! `registerScript` sources are refused loudly, and console eval gets
//! the documented native-compiled refusal — same policy, same wording
//! shape as rust/crystal.
//!
//! Panic safety lives on the OTHER side of the seam: every labelle_go_*
//! export recovers its body (and each script hook individually) — a go
//! panic that unwound out of a cgo-exported function would kill the
//! process — so the glue's containment is a hard requirement, pinned by
//! the go suite's panic tests. Recovered go panics write nothing to
//! stderr (no rust-style default-hook replacement needed), keeping
//! passing test binaries free of the phantom `failed command:` relay.

const std = @import("std");
const contract = @import("../contract.zig");
const eval_mod = @import("../eval.zig");

/// The glue ABI revision this arm drives (`glue.go GoABIVersion`).
/// `Vm.init` refuses a mismatch: the one realistic skew is a STALE
/// archive in the plugin's build cache after a plugin upgrade — that
/// must fail the boot handshake, not corrupt dispatch mid-game.
pub const SUPPORTED_GO_ABI_VERSION: u32 = 1;

// The glue's entry points (native-go/glue.go). Same-binary externs,
// exactly like the contract symbols themselves — the go archive is
// linked into whatever binary this module compiles into (the generated
// game via the assembler's declared build step; the test binary via
// build.zig's go wiring).
extern fn labelle_go_abi_version() u32;
extern fn labelle_go_setup() i32;
extern fn labelle_go_dispatch_inbox() void;
extern fn labelle_go_tick(dt: f32) void;
extern fn labelle_go_deinit() void;

fn logHost(msg: []const u8) void {
    contract.labelle_log(msg.ptr, msg.len);
}

pub const Vm = struct {
    /// Handshake with the linked glue; no state to allocate (the go
    /// runtime booted itself at process start — module doc).
    pub fn init() error{GoGlueVersionMismatch}!Vm {
        const got = labelle_go_abi_version();
        if (got != SUPPORTED_GO_ABI_VERSION) {
            logHost("[scripting] go glue ABI mismatch — the linked " ++
                "liblabelle_go_scripts.a was built by a different plugin " ++
                "version (stale plugin-build cache?); regenerate/rebuild");
            return error.GoGlueVersionMismatch;
        }
        return .{};
    }

    /// Nothing to free: script state is the glue's, dropped by
    /// labelle_go_deinit (the "__teardown_controllers" leg — the shared
    /// Controller always calls it before close). The go runtime itself
    /// stays resident for the process lifetime.
    pub fn close(self: Vm) void {
        _ = self;
    }

    /// Registered SOURCES cannot run in a native-compiled language —
    /// refuse loudly (false = failed to load; the name never enters any
    /// hook registry) instead of silently swallowing a script the
    /// author expects to run. Go game code arrives through the
    /// `Register` convention, not through this seam.
    pub fn loadScript(self: Vm, name: []const u8, source: [:0]const u8) bool {
        _ = self;
        _ = source;
        var buf: [192]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("[scripting] go is native-compiled: registered source '{s}' " ++
            "ignored — implement it in the game's scripts/ dir instead", .{name}) catch {};
        logHost(w.buffered());
        return false;
    }

    /// No per-source hook registry exists (loadScript admits nothing),
    /// so there is never a script to evict.
    pub fn evictScript(self: Vm, name: []const u8) void {
        _ = self;
        _ = name;
    }

    /// Per-registered-source hooks never run here (nothing loads);
    /// returning true keeps the (always-empty in practice) loop inert:
    /// nothing ran, nothing failed, nothing to evict.
    pub fn callScriptHook(self: Vm, script_name: []const u8, hook: []const u8, dt: ?f32) bool {
        _ = self;
        _ = script_name;
        _ = hook;
        _ = dt;
        return true;
    }

    /// The Controller-tier dispatch table — the whole go integration
    /// funnels through these four names (module doc). Unknown names are
    /// a no-op, mirroring the embedded backends' missing-function calls.
    pub fn callLabelleFn(self: Vm, name: [*:0]const u8, dt: ?f32) void {
        _ = self;
        const n = std.mem.span(name);
        if (std.mem.eql(u8, n, "__setup_controllers")) {
            if (labelle_go_setup() != 0) {
                logHost("[scripting] go setup failed — Register() panicked; " ++
                    "no scripts are running (see the log lines above)");
            }
        } else if (std.mem.eql(u8, n, "dispatch_inbox")) {
            labelle_go_dispatch_inbox();
        } else if (std.mem.eql(u8, n, "__tick_controllers")) {
            labelle_go_tick(dt orelse 0);
        } else if (std.mem.eql(u8, n, "__teardown_controllers")) {
            labelle_go_deinit();
        }
    }

    /// The studio console cannot evaluate go — there is no VM to hand
    /// the code to, only compiled machine code. A documented refusal
    /// (ok:false) keeps the console usable for diagnostics instead of
    /// pretending an eval happened.
    pub fn evalConsole(self: Vm, code: []const u8, out: []u8) eval_mod.EvalResult {
        _ = self;
        _ = code;
        _ = out;
        return .{
            .ok = false,
            .text = "eval not supported for native-compiled languages (go) — " ++
                "scripts are compiled into the game; use an embedded-VM language " ++
                "for console evaluation",
        };
    }
};
