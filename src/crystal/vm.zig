//! The crystal sub-module's "VM" (labelle-engine#741, native-compiled
//! family, second language on the rust skeleton): there is no
//! interpreter — game scripts are compiled crystal, built by the
//! plugin's declared steps (crystal build → main-localization; see
//! plugin.labelle `.language_builds`) into a relocatable object LINKED
//! into the game binary. This file adapts the shared Controller's
//! VM-shaped surface onto the glue's labelle_cr_* entry points, the
//! exact labelle_rs_* twin plus one crystal-only leg:
//!
//!   Controller.setup   → Vm.init (labelle_cr_abi_version handshake,
//!                        then ONE-TIME labelle_cr_boot — see below)
//!                        … registered-source loop: no-ops
//!                        → callLabelleFn("__setup_controllers")
//!                          = labelle_cr_setup (Game.register + inits)
//!   Controller.tick    → callLabelleFn("dispatch_inbox")
//!                          = labelle_cr_dispatch_inbox (event fan-out)
//!                        → callLabelleFn("__tick_controllers", dt)
//!                          = labelle_cr_tick (every update(dt))
//!   Controller.deinit  → callLabelleFn("__teardown_controllers")
//!                          = labelle_cr_deinit (deinits, LIFO)
//!                        → Vm.close (no-op)
//!
//! ## The boot leg (crystal-only)
//!
//! Unlike rust, crystal code cannot run before its RUNTIME initializes:
//! GC, scheduler class vars, and — the sharp edge the labelle-engine#734
//! POC hit as "raising APIs segfault" — the program's TOP-LEVEL, which
//! initializes stdlib constants (e.g. String's CHAR_TO_DIGIT digit
//! table: skip it and the first `to_i64` derefs a null slice pointer,
//! crashing at an address equal to the first parsed byte). The glue's
//! `labelle_cr_boot` runs the documented embed sequence (GC.init +
//! Crystal.init_runtime + Crystal.main_user_code) ONCE per process —
//! guarded here, zig-side, so a re-setup after deinit never re-runs the
//! top level. Boot happens on the game's main thread, which is also
//! what registers the host thread's stack with bdw-gc (GC_init detects
//! the calling thread's stack bounds); collections then run normally —
//! the suite forces GC.collect every tick to pin exactly that.
//!
//! The handshake runs BEFORE boot on purpose: a stale localized object
//! in the plugin's build cache must fail fast, before its top-level
//! constant initializers get a chance to run. That ordering is safe
//! because `labelle_cr_abi_version` is pinned to a bare literal return
//! (no allocation, no runtime dependency — glue.cr documents the
//! invariant on the fun itself).
//!
//! `registerScript` sources are refused loudly, and console eval gets
//! the documented native-compiled refusal — same policy, same wording
//! shape as rust.
//!
//! Raise safety lives on the OTHER side of the seam: every labelle_cr_*
//! export wraps its body (and each script hook individually) in
//! begin/rescue — an exception unwinding out of a crystal `fun` into
//! foreign frames finds no handler and crystal KILLS THE PROCESS
//! ("Failed to raise an exception: END_OF_STACK"), so the glue's
//! containment is a hard requirement, pinned by the crystal suite's
//! raise tests.

const std = @import("std");
const contract = @import("../contract.zig");
const eval_mod = @import("../eval.zig");

/// The glue ABI revision this arm drives (`glue.cr CR_ABI_VERSION`).
/// `Vm.init` refuses a mismatch: the one realistic skew is a STALE
/// localized object in the plugin's build cache after a plugin upgrade —
/// that must fail the boot handshake, not corrupt dispatch mid-game.
pub const SUPPORTED_CR_ABI_VERSION: u32 = 1;

// The glue's entry points (native-crystal/src/glue.cr). Same-binary
// externs, exactly like the contract symbols themselves — the localized
// crystal object is linked into whatever binary this module compiles
// into (the generated game via the assembler's declared steps; the test
// binary via build.zig's crystal wiring).
extern fn labelle_cr_abi_version() u32;
extern fn labelle_cr_boot() void;
extern fn labelle_cr_setup() i32;
extern fn labelle_cr_dispatch_inbox() void;
extern fn labelle_cr_tick(dt: f32) void;
extern fn labelle_cr_deinit() void;

/// Crystal's runtime boots at most once per process (re-running the
/// top level would re-initialize every constant and class var behind
/// live state). Zig-side so the guard needs no crystal code to run.
var runtime_booted = false;

fn logHost(msg: []const u8) void {
    contract.labelle_log(msg.ptr, msg.len);
}

pub const Vm = struct {
    /// Handshake with the linked glue, then the one-time runtime boot;
    /// no state to allocate.
    pub fn init() error{CrystalGlueVersionMismatch}!Vm {
        const got = labelle_cr_abi_version();
        if (got != SUPPORTED_CR_ABI_VERSION) {
            logHost("[scripting] crystal glue ABI mismatch — the linked " ++
                "labelle_crystal_scripts object was built by a different " ++
                "plugin version (stale plugin-build cache?); regenerate/rebuild");
            return error.CrystalGlueVersionMismatch;
        }
        if (!runtime_booted) {
            labelle_cr_boot();
            runtime_booted = true;
        }
        return .{};
    }

    /// Nothing to free: script state is the glue's, dropped by
    /// labelle_cr_deinit (the "__teardown_controllers" leg — the shared
    /// Controller always calls it before close). The crystal runtime
    /// itself stays booted for the process lifetime (see runtime_booted).
    pub fn close(self: Vm) void {
        _ = self;
    }

    /// Registered SOURCES cannot run in a native-compiled language —
    /// refuse loudly (false = failed to load; the name never enters any
    /// hook registry) instead of silently swallowing a script the author
    /// expects to run. Crystal game code arrives through the `Game.register`
    /// convention, not through this seam.
    pub fn loadScript(self: Vm, name: []const u8, source: [:0]const u8) bool {
        _ = self;
        _ = source;
        var buf: [192]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("[scripting] crystal is native-compiled: registered source '{s}' " ++
            "ignored — implement it in the game's crystal/ dir instead", .{name}) catch {};
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

    /// The Controller-tier dispatch table — the whole crystal integration
    /// funnels through these four names (module doc). Unknown names are
    /// a no-op, mirroring the embedded backends' missing-function calls.
    pub fn callLabelleFn(self: Vm, name: [*:0]const u8, dt: ?f32) void {
        _ = self;
        const n = std.mem.span(name);
        if (std.mem.eql(u8, n, "__setup_controllers")) {
            if (labelle_cr_setup() != 0) {
                logHost("[scripting] crystal setup failed — register() raised; " ++
                    "no scripts are running (see the log lines above)");
            }
        } else if (std.mem.eql(u8, n, "dispatch_inbox")) {
            labelle_cr_dispatch_inbox();
        } else if (std.mem.eql(u8, n, "__tick_controllers")) {
            labelle_cr_tick(dt orelse 0);
        } else if (std.mem.eql(u8, n, "__teardown_controllers")) {
            labelle_cr_deinit();
        }
    }

    /// The studio console cannot evaluate crystal — there is no VM to
    /// hand the code to, only compiled machine code. A documented refusal
    /// (ok:false) keeps the console usable for diagnostics instead of
    /// pretending an eval happened.
    pub fn evalConsole(self: Vm, code: []const u8, out: []u8) eval_mod.EvalResult {
        _ = self;
        _ = code;
        _ = out;
        return .{
            .ok = false,
            .text = "eval not supported for native-compiled languages (crystal) — " ++
                "scripts are compiled into the game; use an embedded-VM language " ++
                "for console evaluation",
        };
    }
};
