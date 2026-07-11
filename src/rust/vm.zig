//! The rust sub-module's "VM" (labelle-engine#741, native-compiled
//! family): there is no interpreter to embed — game scripts are compiled
//! rust, built by the plugin's declared cargo step into
//! `liblabelle_rust_scripts.a` and LINKED into the game binary. This
//! file is the thin dispatcher that adapts the shared Controller's
//! VM-shaped surface (init/close/loadScript/callScriptHook/evictScript/
//! callLabelleFn/evalConsole — src/root.zig picks it by the comptime
//! backend switch) onto the crate glue's C entry points:
//!
//!   Controller.setup   → Vm.init (labelle_rs_abi_version handshake)
//!                        … registered-source loop: no-ops (see below)
//!                        → callLabelleFn("__setup_controllers")
//!                          = labelle_rs_setup (game register() + inits)
//!   Controller.tick    → callLabelleFn("dispatch_inbox")
//!                          = labelle_rs_dispatch_inbox (event fan-out)
//!                        → callLabelleFn("__tick_controllers", dt)
//!                          = labelle_rs_tick (every update(dt))
//!   Controller.deinit  → callLabelleFn("__teardown_controllers")
//!                          = labelle_rs_deinit (deinits, LIFO)
//!                        → Vm.close (no-op — nothing to free)
//!
//! The mapping rides the CONTROLLER-tier callLabelleFn names on purpose:
//! native scripts are registered structures (the ruby-controller analog),
//! not runtime-loaded chunks, so they boot after the (empty) script-load
//! phase and tear down first, and the shared Controller stays untouched.
//!
//! `registerScript` sources are MEANINGLESS here — rust arrives as
//! machine code, not text. The assembler's native-language splice never
//! emits registrations for rust projects; a hand-registered source is
//! refused loudly (loadScript logs + returns false) instead of silently
//! pretending to run.
//!
//! Panic safety lives on the OTHER side of the seam: every labelle_rs_*
//! export wraps its body (and each script hook individually) in
//! catch_unwind — a rust panic that unwound into this file would be
//! instant UB, so the glue's containment is a hard requirement, pinned
//! by the rust suite's panic tests.

const std = @import("std");
const contract = @import("../contract.zig");
const eval_mod = @import("../eval.zig");

/// The glue ABI revision this arm drives (`glue.rs RS_ABI_VERSION`).
/// `Vm.init` refuses a mismatch: the one realistic skew is a STALE
/// staticlib in the plugin's build cache after a plugin upgrade — that
/// must fail the boot handshake, not corrupt dispatch mid-game.
pub const SUPPORTED_RS_ABI_VERSION: u32 = 1;

// The crate glue's entry points (native/src/glue.rs). Same-binary
// externs, exactly like the contract symbols themselves — the cargo
// artifact is linked into whatever binary this module compiles into
// (the generated game via the assembler's build step; the test binary
// via build.zig's cargo wiring).
extern fn labelle_rs_abi_version() u32;
extern fn labelle_rs_setup() i32;
extern fn labelle_rs_dispatch_inbox() void;
extern fn labelle_rs_tick(dt: f32) void;
extern fn labelle_rs_deinit() void;

fn logHost(msg: []const u8) void {
    contract.labelle_log(msg.ptr, msg.len);
}

pub const Vm = struct {
    /// Handshake with the linked crate glue; no state to allocate.
    pub fn init() error{RustGlueVersionMismatch}!Vm {
        const got = labelle_rs_abi_version();
        if (got != SUPPORTED_RS_ABI_VERSION) {
            logHost("[scripting] rust glue ABI mismatch — the linked " ++
                "liblabelle_rust_scripts.a was built by a different plugin " ++
                "version (stale plugin-build cache?); regenerate/rebuild");
            return error.RustGlueVersionMismatch;
        }
        return .{};
    }

    /// Nothing to free: script state is the crate's, dropped by
    /// labelle_rs_deinit (the "__teardown_controllers" leg — the shared
    /// Controller always calls it before close).
    pub fn close(self: Vm) void {
        _ = self;
    }

    /// Registered SOURCES cannot run in a native-compiled language —
    /// refuse loudly (false = failed to load; the name never enters any
    /// hook registry) instead of silently swallowing a script the author
    /// expects to run. Rust game code arrives through the crate's
    /// `register` convention, not through this seam.
    pub fn loadScript(self: Vm, name: []const u8, source: [:0]const u8) bool {
        _ = self;
        _ = source;
        var buf: [192]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("[scripting] rust is native-compiled: registered source '{s}' " ++
            "ignored — implement it in the game's rust/ dir instead", .{name}) catch {};
        logHost(w.buffered());
        return false;
    }

    /// No per-source hook registry exists (loadScript admits nothing),
    /// so there is never a script to evict.
    pub fn evictScript(self: Vm, name: []const u8) void {
        _ = self;
        _ = name;
    }

    /// Per-registered-source hooks never run here (nothing loads), and
    /// the Controller ignores init-hook results only for loaded scripts —
    /// returning true keeps the (always-empty in practice) loop inert:
    /// nothing ran, nothing failed, nothing to evict.
    pub fn callScriptHook(self: Vm, script_name: []const u8, hook: []const u8, dt: ?f32) bool {
        _ = self;
        _ = script_name;
        _ = hook;
        _ = dt;
        return true;
    }

    /// The Controller-tier dispatch table — the whole rust integration
    /// funnels through these four names (module doc). Unknown names are
    /// a no-op, mirroring the embedded backends' missing-function calls.
    pub fn callLabelleFn(self: Vm, name: [*:0]const u8, dt: ?f32) void {
        _ = self;
        const n = std.mem.span(name);
        if (std.mem.eql(u8, n, "__setup_controllers")) {
            if (labelle_rs_setup() != 0) {
                logHost("[scripting] rust setup failed — register() panicked; " ++
                    "no scripts are running (see the log lines above)");
            }
        } else if (std.mem.eql(u8, n, "dispatch_inbox")) {
            labelle_rs_dispatch_inbox();
        } else if (std.mem.eql(u8, n, "__tick_controllers")) {
            labelle_rs_tick(dt orelse 0);
        } else if (std.mem.eql(u8, n, "__teardown_controllers")) {
            labelle_rs_deinit();
        }
    }

    /// The studio console cannot evaluate rust — there is no VM to hand
    /// the code to, only compiled machine code. A documented refusal
    /// (ok:false) keeps the console usable for diagnostics instead of
    /// pretending an eval happened.
    pub fn evalConsole(self: Vm, code: []const u8, out: []u8) eval_mod.EvalResult {
        _ = self;
        _ = code;
        _ = out;
        return .{
            .ok = false,
            .text = "eval not supported for native-compiled languages (rust) — " ++
                "scripts are compiled into the game; use an embedded-VM language " ++
                "for console evaluation",
        };
    }
};
