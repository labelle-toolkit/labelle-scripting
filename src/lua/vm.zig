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
//! tick; the other scripts (and the game) keep running.
//!
//! Script isolation: each registered script chunk runs under its own `_ENV`
//! table whose metatable falls back to the real globals. Scripts therefore
//! read the shared prelude (`labelle`, `Entity`, `game`, `json`) normally,
//! but their own top-level declarations — crucially `init`/`update`/
//! `deinit`, which every script defines — land in their private table
//! instead of colliding last-writer-wins in `_G`. The prelude keeps the
//! env registry in the global `__labelle_scripts` (name → env), which is
//! how `callScriptHook` finds each script's functions.

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
    pub extern fn lua_createtable(L: ?*State, narr: c_int, nrec: c_int) void;
    pub extern fn lua_pushcclosure(L: ?*State, f: CFn, n: c_int) void;
    pub extern fn lua_pushlstring(L: ?*State, s: [*]const u8, len: usize) [*]const u8;
    pub extern fn lua_pushinteger(L: ?*State, n: i64) void;
    pub extern fn lua_pushnumber(L: ?*State, n: f64) void;
    pub extern fn lua_pushboolean(L: ?*State, b: c_int) void;

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

    // The C entry point behind Lua's `debug.traceback` (db_traceback in
    // ldblib.c is a thin wrapper over it) — same trace text, but immune to
    // scripts replacing the `debug` global.
    pub extern fn luaL_traceback(L: ?*State, L1: ?*State, msg: ?[*]const u8, level: c_int) void;
};

/// Global name of the prelude-owned env registry: `__labelle_scripts[name]`
/// is the private `_ENV` table of the script registered under `name`.
const SCRIPTS_REGISTRY: [*:0]const u8 = "__labelle_scripts";

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
        return self.protectedCall(0, 0, name); // runs the chunk body
    }

    /// Call `hook` ("init"/"update"/"deinit") of the script registered as
    /// `script_name`, passing `dt` when given. Looks the function up with
    /// rawget on the script's OWN env — the `__index = _G` fallback must
    /// not leak another script's hook in (script B without update() would
    /// otherwise run whatever `update` _G happens to see). Missing hooks
    /// are simply skipped: all three are optional.
    pub fn callScriptHook(self: Vm, script_name: []const u8, hook: []const u8, dt: ?f32) void {
        const L = self.L;
        _ = c.lua_getglobal(L, SCRIPTS_REGISTRY); // [registry]
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_settop(L, -2);
            return;
        }
        _ = c.lua_pushlstring(L, script_name.ptr, script_name.len); // [registry, name]
        _ = c.lua_rawget(L, -2); // [registry, env]
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_settop(L, -3);
            return;
        }
        _ = c.lua_pushlstring(L, hook.ptr, hook.len); // [registry, env, hookname]
        _ = c.lua_rawget(L, -2); // [registry, env, fn?]
        if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
            c.lua_settop(L, -4);
            return;
        }
        var nargs: c_int = 0;
        if (dt) |v| {
            c.lua_pushnumber(L, v);
            nargs = 1;
        }
        _ = self.protectedCall(nargs, 0, script_name);
        c.lua_settop(L, -3); // pop env + registry
    }

    /// Call a prelude function `labelle.<name>` with no arguments — how the
    /// Controller triggers `labelle.dispatch_inbox()` at tick start. Silently
    /// a no-op when the prelude (or the function) is missing.
    pub fn callLabelleFn(self: Vm, name: [*:0]const u8) void {
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
        _ = self.protectedCall(0, 0, "dispatch");
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
