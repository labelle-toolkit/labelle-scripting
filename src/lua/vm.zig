//! Lua 5.4 state management for the `lua` sub-module.
//!
//! The C API is hand-declared (the POC pattern from labelle-engine's
//! poc/language-plugins spike) instead of `@cImport`ed: the ~30 symbols we
//! touch are a stable, documented ABI, and skipping translate-c keeps the
//! plugin's build free of C-header parsing quirks across targets. The Lua
//! sources themselves are vendored by build.zig (onelua.c, -DMAKE_LIB) into
//! this same module, so the externs resolve in-binary — the same linking
//! model the Script Runtime Contract uses toward the host game.
//!
//! Error policy (the load-bearing part): every entry into Lua goes through
//! `protectedCall`, a pcall with a traceback message handler. A script that
//! throws gets its full stack trace logged through `labelle_log` and the
//! error is swallowed — a broken behavior script must NEVER kill the game
//! tick; the other scripts (and the game) keep running. Failure at the two
//! boot points is stricter: a chunk body that errors (loadScript) or an
//! `init()` that errors (evictScript, driven by the Controller) removes the
//! script's env from the registry entirely, so a half-initialized script
//! never receives `update`/`deinit` hooks.
//!
//! GC pacing: this module also owns the per-tick GC step budget
//! (`gc_step_budget_kb`/`stepGc` below) — the prelude's end-of-tick
//! housekeeping drives one budgeted `lua_gc(LUA_GCSTEP, …)` per
//! Controller tick so collection cost smears across frames instead of
//! piling into mid-frame pauses.
//!
//! Script isolation: each registered script chunk runs under its own `_ENV`
//! table whose metatable falls back to the real globals. Scripts therefore
//! read the shared prelude (`labelle`, `Entity`, `game`, `json`) normally,
//! but their own top-level declarations — crucially `init`/`update`/
//! `deinit`, which every script defines — land in their private table
//! instead of colliding last-writer-wins in `_G`. The prelude keeps the
//! env registry in the global `__labelle_scripts` (name → env), which is
//! how `callScriptHook` finds each script's functions.
//!
//! Current-script tracking: around EVERY entry from the VM into script
//! code — the chunk body in `loadScript`, each hook in `callScriptHook` —
//! the global `__labelle_current_script` is set to the script's name and
//! cleared (nil) after. It is the VM-truth answer to "whose code is
//! running", which the prelude's `labelle.on` reads to record handler
//! ownership (and `dispatch_inbox` re-stamps around each handler call).
//! Ownership canNOT be derived from the registering caller's `_ENV`
//! upvalue instead: a script-local helper that closes over an alias of
//! `labelle.on` touches no globals, carries no `_ENV`, and would walk to
//! owner nil — exempting its handlers from the eviction purge.

const std = @import("std");
const contract = @import("../contract.zig");

/// Hand-declared Lua 5.4 C API — just the slice this plugin uses.
/// Signatures mirror lua.h/lauxlib.h; `lua_State` stays opaque.
pub const c = struct {
    pub const State = opaque {};
    pub const CFn = *const fn (?*State) callconv(.c) c_int;
    /// lua_KFunction — never used (no coroutine continuations here), but
    /// lua_pcallk's ABI wants the parameter.
    pub const KFn = *const fn (?*State, c_int, isize) callconv(.c) c_int;

    pub const LUA_OK: c_int = 0;
    pub const LUA_TNIL: c_int = 0;
    pub const LUA_TTABLE: c_int = 5;
    pub const LUA_TFUNCTION: c_int = 6;
    /// lua_gc option: one incremental collection step (lua.h LUA_GCSTEP).
    pub const LUA_GCSTEP: c_int = 5;
    /// -LUAI_MAXSTACK - 1000 with the default LUAI_MAXSTACK = 1_000_000
    /// (luaconf.h) — the pseudo-index of the registry.
    pub const LUA_REGISTRYINDEX: c_int = -1001000;
    /// Registry slot of the globals table (lua.h LUA_RIDX_GLOBALS).
    pub const LUA_RIDX_GLOBALS: i64 = 2;

    // State lifecycle.
    pub extern fn luaL_newstate() ?*State;
    pub extern fn luaL_openlibs(L: ?*State) void;
    pub extern fn lua_close(L: ?*State) void;

    // Loading and calling.
    pub extern fn luaL_loadbufferx(L: ?*State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int;
    pub extern fn lua_pcallk(L: ?*State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?KFn) c_int;
    /// Raises a Lua error with the value on top of the stack (longjmps back
    /// into the innermost pcall — only ever called from inside a C closure
    /// invoked by Lua, where that jump is the defined error protocol).
    pub extern fn lua_error(L: ?*State) c_int;

    // Stack manipulation.
    pub extern fn lua_gettop(L: ?*State) c_int;
    pub extern fn lua_settop(L: ?*State, idx: c_int) void;
    pub extern fn lua_pushvalue(L: ?*State, idx: c_int) void;
    pub extern fn lua_rotate(L: ?*State, idx: c_int, n: c_int) void;
    pub extern fn lua_type(L: ?*State, idx: c_int) c_int;

    // Pushing values.
    pub extern fn lua_pushnil(L: ?*State) void;
    pub extern fn lua_createtable(L: ?*State, narr: c_int, nrec: c_int) void;
    pub extern fn lua_pushcclosure(L: ?*State, f: CFn, n: c_int) void;
    pub extern fn lua_pushlstring(L: ?*State, s: [*]const u8, len: usize) [*]const u8;
    pub extern fn lua_pushinteger(L: ?*State, n: i64) void;
    pub extern fn lua_pushnumber(L: ?*State, n: f64) void;
    pub extern fn lua_pushboolean(L: ?*State, b: c_int) void;
    /// GC-owned scratch memory (raises on OOM — the standard C-closure
    /// longjmp, safe in defer-free shim frames). The block lives on the
    /// stack; the frame's end releases it to the collector.
    pub extern fn lua_newuserdatauv(L: ?*State, sz: usize, nuvalue: c_int) ?*anyopaque;

    // Table and global access.
    pub extern fn lua_getglobal(L: ?*State, name: [*:0]const u8) c_int;
    pub extern fn lua_setglobal(L: ?*State, name: [*:0]const u8) void;
    pub extern fn lua_getfield(L: ?*State, idx: c_int, k: [*:0]const u8) c_int;
    pub extern fn lua_setfield(L: ?*State, idx: c_int, k: [*:0]const u8) void;
    pub extern fn lua_settable(L: ?*State, idx: c_int) void;
    pub extern fn lua_rawget(L: ?*State, idx: c_int) c_int;
    pub extern fn lua_rawgeti(L: ?*State, idx: c_int, n: i64) c_int;
    pub extern fn lua_setmetatable(L: ?*State, idx: c_int) c_int;
    pub extern fn lua_setupvalue(L: ?*State, funcindex: c_int, n: c_int) ?[*:0]const u8;

    // Reading values.
    pub extern fn lua_tolstring(L: ?*State, idx: c_int, len: ?*usize) ?[*]const u8;
    pub extern fn lua_tointegerx(L: ?*State, idx: c_int, isnum: ?*c_int) i64;
    pub extern fn lua_tonumberx(L: ?*State, idx: c_int, isnum: ?*c_int) f64;

    // Garbage collection. VARIADIC in 5.4 (the option selects how many
    // int arguments follow) — the declaration must say so, or the call
    // ABI is wrong on targets where varargs differ from fixed args.
    pub extern fn lua_gc(L: ?*State, what: c_int, ...) c_int;

    // The C entry point behind Lua's `debug.traceback` (db_traceback in
    // ldblib.c is a thin wrapper over it) — same trace text, but immune to
    // scripts replacing the `debug` global.
    pub extern fn luaL_traceback(L: ?*State, L1: ?*State, msg: ?[*]const u8, level: c_int) void;
};

/// Global name of the prelude-owned env registry: `__labelle_scripts[name]`
/// is the private `_ENV` table of the script registered under `name`.
const SCRIPTS_REGISTRY: [*:0]const u8 = "__labelle_scripts";

/// Global holding the name of the script whose code the VM is currently
/// executing (nil between entries) — see the module doc's current-script
/// tracking section. Written by `setCurrentScript` around every VM→script
/// entry; read by the prelude's `labelle.on` for handler ownership.
const CURRENT_SCRIPT_GLOBAL: [*:0]const u8 = "__labelle_current_script";

/// Longest accepted script name for the "@<name>" chunkname buffer. Chunk
/// names beyond this are truncated — error locations just lose their tail.
const CHUNKNAME_CAP = 128;

/// Cap for one formatted error log line. Tracebacks can outgrow anything;
/// truncation beats a heap allocation inside the error path.
const ERROR_LOG_CAP = 2048;

/// Message handler installed by `protectedCall`: turns the error value into
/// "<message>\nstack traceback:\n..." BEFORE the stack unwinds (afterwards
/// the frames are gone — this is why pcall alone isn't enough).
fn msghTraceback(L: ?*c.State) callconv(.c) c_int {
    var len: usize = 0;
    // NULL for non-string error values (error(t) with a table): the trace
    // still gets produced, just without a leading message.
    const msg = c.lua_tolstring(L, 1, &len);
    // Lua strings are internally NUL-terminated, so the pointer doubles as
    // the C string luaL_traceback expects.
    c.luaL_traceback(L, L, msg, 1);
    return 1;
}

/// Format + route one error line through the host's log sink ("context" is
/// the failing script's name, empty for anonymous chunks). Safe when the
/// host is unbound — labelle_log is a no-op then.
fn logError(context: []const u8, text: []const u8) void {
    var buf: [ERROR_LOG_CAP]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // Truncation on overflow is fine — the head of a traceback carries the
    // message and the innermost frames, which is the actionable part.
    if (context.len > 0)
        w.print("[lua] {s}: {s}", .{ context, text }) catch {}
    else
        w.print("[lua] {s}", .{text}) catch {};
    const line = w.buffered();
    contract.labelle_log(line.ptr, line.len);
}

/// Per-tick GC step budget in KB — what the end-of-tick housekeeping
/// (the prelude's `labelle.__tick_controllers`, via the raw_gc_step
/// shim) passes to `lua_gc(LUA_GCSTEP, …)`.
///
/// Semantics, verified against the vendored 5.4.8 lapi.c: the budget is
/// ADDED to the collector's debt (`budget * 1024 + GCdebt`) and steps
/// run only while the resulting debt is positive — so the call performs
/// at most `budget` KB worth of extra collection, and nothing at all
/// while the collector is ahead. `0` asks for one "basic step" (the
/// collector's own stepsize, 8 KB by default); negative disables the
/// per-tick step entirely.
///
/// Interaction with Lua's own pacing: 5.4 boots in INCREMENTAL mode
/// (pause 200, stepmul 100, stepsize 8 KB) and that organic,
/// allocation-driven pacing stays untouched as the backstop — this seam
/// never stops the collector, it only front-loads work at the tick
/// boundary. A budget at or above the scripts' per-tick allocation rate
/// moves effectively ALL collection into that controlled slot (one
/// tick's garbage at a time — smeared, never a full-collect spike); a
/// smaller budget shifts part of it and the organic mid-frame steps
/// make up the rest.
///
/// Process-global like the VM itself and deliberately NOT reset between
/// VMs — it is configuration, not VM state. Seam for tests (via
/// `labelle.raw_gc_set_step_budget`) and, later, plugin params
/// (labelle-assembler#591). Default: 64 KB covers a modest scripted
/// game's per-tick allocation with the organic pacing as overflow.
pub var gc_step_budget_kb: c_int = 64;

/// Monotonic count of budgeted GC steps driven (calls that reached
/// lua_gc — the budget ≥ 0 path). Never reset; tests assert deltas,
/// mirroring the bindings' scratch_growth_count.
pub var gc_step_count: usize = 0;

/// Monotonic count of budgeted steps that ENDED a collection cycle
/// (lua_gc returned 1). Cycles completing here mean collection keeps
/// making it all the way around inside the per-tick slot — no full
/// collect ever needed.
pub var gc_cycle_count: usize = 0;

/// One budgeted incremental GC step (see gc_step_budget_kb). Returns
/// lua_gc's result — 1 when the step finished a collection cycle, 0
/// otherwise, -1 when the collector refused (internally stopped, e.g.
/// during an emergency collection) — or 0 without calling when the
/// budget is negative (disabled).
pub fn stepGc(L: ?*c.State) c_int {
    if (gc_step_budget_kb < 0) return 0;
    const rc = c.lua_gc(L, c.LUA_GCSTEP, gc_step_budget_kb);
    gc_step_count += 1;
    if (rc == 1) gc_cycle_count += 1;
    return rc;
}

/// One embedded Lua 5.4 VM. Plain value (a single opaque pointer) — the
/// Controller owns exactly one per game process.
pub const Vm = struct {
    L: *c.State,

    pub fn init() error{LuaStateInit}!Vm {
        const L = c.luaL_newstate() orelse return error.LuaStateInit;
        // Full stdlib: game scripts are first-party content (they ship with
        // the game), so sandboxing io/os away buys nothing and costs script
        // authors the tools they expect.
        c.luaL_openlibs(L);
        return .{ .L = L };
    }

    /// Close the VM. Lua's GC releases every script, env and binding —
    /// this is the whole teardown story.
    pub fn close(self: Vm) void {
        c.lua_close(self.L);
    }

    /// Call the function sitting below `nargs` arguments on the stack under
    /// the traceback message handler. On error: log through labelle_log,
    /// leave the stack as it was before the callee was pushed, return false.
    /// `context` names the caller (script or chunk) in the log line.
    pub fn protectedCall(self: Vm, nargs: c_int, nresults: c_int, context: []const u8) bool {
        const L = self.L;
        const fn_index = c.lua_gettop(L) - nargs; // where the callee sits
        c.lua_pushcclosure(L, msghTraceback, 0);
        // Rotate the msgh below the callee: [msgh, fn, args...] — pcall
        // wants the handler's index to survive the call frame.
        c.lua_rotate(L, fn_index, 1);
        const rc = c.lua_pcallk(L, nargs, nresults, fn_index, 0, null);
        if (rc == c.LUA_OK) {
            // Results sit above the msgh; slide it out from under them.
            c.lua_rotate(L, fn_index, -1);
            c.lua_settop(L, -2);
            return true;
        }
        var len: usize = 0;
        const msg = c.lua_tolstring(L, -1, &len);
        logError(context, if (msg) |m| m[0..len] else "(non-string error)");
        c.lua_settop(L, fn_index - 1); // drop msgh + error object
        return false;
    }

    /// Compile + run an anonymous chunk in the REAL globals (no env
    /// isolation) — how the prelude installs itself. Returns false (logged)
    /// on compile or runtime error.
    pub fn runChunk(self: Vm, chunkname: [*:0]const u8, source: []const u8) bool {
        if (c.luaL_loadbufferx(self.L, source.ptr, source.len, chunkname, "t") != c.LUA_OK) {
            self.logTopError("");
            return false;
        }
        return self.protectedCall(0, 0, "");
    }

    /// Compile + run one registered script chunk under a fresh private
    /// `_ENV` (see module docs) and record its env in `__labelle_scripts`.
    /// The chunkname is "@<name>" so every error and traceback line reads
    /// "<name>:<line>". Returns false (logged) on any failure; the caller
    /// moves on to the next script — one broken file must not take the
    /// rest down with it.
    pub fn loadScript(self: Vm, name: []const u8, source: [:0]const u8) bool {
        const L = self.L;

        var namebuf: [CHUNKNAME_CAP]u8 = undefined;
        namebuf[0] = '@';
        const n = @min(name.len, namebuf.len - 2);
        @memcpy(namebuf[1 .. 1 + n], name[0..n]);
        namebuf[1 + n] = 0;
        const chunkname: [*:0]const u8 = @ptrCast(&namebuf);

        if (c.luaL_loadbufferx(L, source.ptr, source.len, chunkname, "t") != c.LUA_OK) {
            self.logTopError("load"); // compile error text already carries "<name>:<line>"
            return false;
        }

        // env = setmetatable({}, { __index = _G })
        c.lua_createtable(L, 0, 8); // [chunk, env]
        c.lua_createtable(L, 0, 1); // [chunk, env, meta]
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, c.LUA_RIDX_GLOBALS); // [chunk, env, meta, _G]
        c.lua_setfield(L, -2, "__index"); // [chunk, env, meta]
        _ = c.lua_setmetatable(L, -2); // [chunk, env]

        // __labelle_scripts[name] = env. The registry is a plain prelude
        // table; if the prelude never ran we must bail BEFORE lua_settable,
        // which would raise (and longjmp through this Zig frame).
        _ = c.lua_getglobal(L, SCRIPTS_REGISTRY); // [chunk, env, registry]
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_settop(L, -4); // drop registry + env + chunk
            logError("", "script registry missing — prelude not installed?");
            return false;
        }
        _ = c.lua_pushlstring(L, name.ptr, name.len); // [chunk, env, registry, name]
        c.lua_pushvalue(L, -3); // [chunk, env, registry, name, env]
        c.lua_settable(L, -3); // [chunk, env, registry]
        c.lua_settop(L, -2); // [chunk, env]

        // Wire the env as the chunk's _ENV (upvalue 1 of every main chunk).
        if (c.lua_setupvalue(L, -2, 1) == null) {
            // Unreachable for main chunks, but if it ever happens the env
            // was NOT consumed — drop it and run in globals rather than
            // corrupting the stack.
            c.lua_settop(L, -2);
        }
        // The chunk body is a VM→script entry: stamp the current script
        // so `labelle.on` at chunk scope attributes its handlers here.
        self.setCurrentScript(name);
        const body_ok = self.protectedCall(0, 0, name); // runs the chunk body
        self.setCurrentScript(null);
        if (!body_ok) {
            // The body failed AFTER its env went into the registry, and
            // whatever it managed to define before erroring (an `update`,
            // say) must not receive hooks on a half-initialized script.
            // protectedCall already logged the traceback; pull the env
            // back out — and purge any handlers the body registered
            // before erroring (a chunk-scope `labelle.on` above the
            // failing line already landed in the prelude's table).
            self.removeScriptEnv(name);
            self.purgeScriptHandlers(name);
            return false;
        }
        return true;
    }

    /// Stamp (or clear, with null) the `__labelle_current_script` global —
    /// the VM-truth "whose code is running" marker every VM→script entry
    /// sets and clears (see the module doc). A plain global write: script
    /// envs only SHADOW globals (their writes land in the private env), so
    /// scripts can't clobber it by accident.
    fn setCurrentScript(self: Vm, name: ?[]const u8) void {
        const L = self.L;
        if (name) |n| {
            _ = c.lua_pushlstring(L, n.ptr, n.len);
        } else {
            c.lua_pushnil(L);
        }
        c.lua_setglobal(L, CURRENT_SCRIPT_GLOBAL);
    }

    /// Pull `name`'s env out of `__labelle_scripts`, making the script
    /// invisible to `callScriptHook` (hooks rawget the env by name and
    /// silently skip missing entries). No-op when the registry — or the
    /// entry — is missing.
    fn removeScriptEnv(self: Vm, name: []const u8) void {
        const L = self.L;
        _ = c.lua_getglobal(L, SCRIPTS_REGISTRY); // [registry]
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_settop(L, -2);
            return;
        }
        _ = c.lua_pushlstring(L, name.ptr, name.len); // [registry, name]
        c.lua_pushnil(L); // [registry, name, nil]
        c.lua_settable(L, -3); // [registry] — plain table, cannot raise
        c.lua_settop(L, -2); // []
    }

    /// Quarantine a script whose `init()` failed: remove its env so the
    /// `update`/`deinit` loops skip it — a half-initialized script must not
    /// keep receiving hooks — purge its `labelle.on` handlers (chunk-scope
    /// subscriptions would otherwise keep firing into the broken state),
    /// and log the eviction once (the init traceback alone would not
    /// explain why the script went silent afterwards).
    pub fn evictScript(self: Vm, name: []const u8) void {
        self.removeScriptEnv(name);
        self.purgeScriptHandlers(name);
        logError(name, "init() failed — script evicted; update/deinit will not run");
    }

    /// Drop every event handler `name` registered through `labelle.on` —
    /// the prelude-side half of eviction, via its `__labelle_purge_handlers`
    /// hook. Missing hook (prelude never installed) is a silent no-op; a
    /// raising purge is logged like any script error by protectedCall.
    fn purgeScriptHandlers(self: Vm, name: []const u8) void {
        const L = self.L;
        _ = c.lua_getglobal(L, "__labelle_purge_handlers"); // [fn?]
        if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
            c.lua_settop(L, -2);
            return;
        }
        _ = c.lua_pushlstring(L, name.ptr, name.len); // [fn, name]
        _ = self.protectedCall(1, 0, name);
    }

    /// Call `hook` ("init"/"update"/"deinit") of the script registered as
    /// `script_name`, passing `dt` when given. Looks the function up with
    /// rawget on the script's OWN env — the `__index = _G` fallback must
    /// not leak another script's hook in (script B without update() would
    /// otherwise run whatever `update` _G happens to see). Missing hooks
    /// are simply skipped: all three are optional. Returns false only when
    /// the hook RAN and raised (missing script/hook is not a failure) —
    /// how the Controller detects a failed `init()` to evict.
    pub fn callScriptHook(self: Vm, script_name: []const u8, hook: []const u8, dt: ?f32) bool {
        const L = self.L;
        _ = c.lua_getglobal(L, SCRIPTS_REGISTRY); // [registry]
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_settop(L, -2);
            return true;
        }
        _ = c.lua_pushlstring(L, script_name.ptr, script_name.len); // [registry, name]
        _ = c.lua_rawget(L, -2); // [registry, env]
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_settop(L, -3);
            return true;
        }
        _ = c.lua_pushlstring(L, hook.ptr, hook.len); // [registry, env, hookname]
        _ = c.lua_rawget(L, -2); // [registry, env, fn?]
        if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
            c.lua_settop(L, -4);
            return true;
        }
        var nargs: c_int = 0;
        if (dt) |v| {
            c.lua_pushnumber(L, v);
            nargs = 1;
        }
        // Hooks are VM→script entries: stamp the current script so a
        // `labelle.on` inside init()/update() attributes its handlers to
        // this script (aliases and local helpers included).
        self.setCurrentScript(script_name);
        const ok = self.protectedCall(nargs, 0, script_name);
        self.setCurrentScript(null);
        c.lua_settop(L, -3); // pop env + registry
        return ok;
    }

    /// Call a prelude function `labelle.<name>`, passing `dt` when given —
    /// how the Controller triggers `labelle.dispatch_inbox()` at tick
    /// start (and the controller-tier sweeps on backends that have one).
    /// Silently a no-op when the prelude (or the function) is missing —
    /// which is exactly how this backend skips the controller hooks.
    pub fn callLabelleFn(self: Vm, name: [*:0]const u8, dt: ?f32) void {
        const L = self.L;
        _ = c.lua_getglobal(L, "labelle"); // [labelle]
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_settop(L, -2);
            return;
        }
        _ = c.lua_getfield(L, -1, name); // [labelle, fn?]
        if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
            c.lua_settop(L, -3);
            return;
        }
        var nargs: c_int = 0;
        if (dt) |v| {
            c.lua_pushnumber(L, v);
            nargs = 1;
        }
        _ = self.protectedCall(nargs, 0, "dispatch");
        c.lua_settop(L, -2); // pop labelle
    }

    /// Log + pop the error message a failed luaL_loadbufferx left on top
    /// (compile errors already carry "<chunkname>:<line>").
    fn logTopError(self: Vm, prefix: []const u8) void {
        var len: usize = 0;
        const msg = c.lua_tolstring(self.L, -1, &len);
        logError(prefix, if (msg) |m| m[0..len] else "(no message)");
        c.lua_settop(self.L, -2);
    }
};
