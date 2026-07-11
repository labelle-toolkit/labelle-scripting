//! Declare-mode extraction core (labelle-declare, RFC-LANGUAGE-PLUGINS
//! revs 6-7, labelle-engine#237).
//!
//! Runs each script CHUNK BODY — never init/update/deinit — in a fresh Lua
//! VM where the only global a script can see is the declare stub `labelle`
//! table (tools/declare/declare_prelude.lua): `labelle.component(...)`
//! records a schema declaration, every other `labelle.*` is a silent
//! no-op, and the whole stdlib is absent. One DSL, two consumers: at game
//! runtime the SAME line yields a component ref (src/lua/prelude.lua); at
//! generate time, run through this extractor, it yields the schema the
//! assembler codegens real Zig components from.
//!
//! Separate from src/lua/vm.zig on purpose: vm.zig's error paths log
//! through the Script Runtime Contract's `labelle_log` extern, which only
//! the HOST GAME binary exports — a standalone tool linking vm.zig would
//! not link. This file follows vm.zig's hand-declared-extern PATTERN with
//! its own (smaller) C-API slice and no contract dependency; the Lua
//! objects themselves come from whichever module compiled them into the
//! enclosing binary (the exe root embeds them via build.zig; the test
//! binary reuses the ones the `labelle_scripting` module already carries).
//!
//! Error policy: extraction is a BUILD step — the first malformed
//! declaration (or erroring chunk body) aborts with a file-and-line
//! bearing message (`Outcome.failure`); there is no evict-and-continue
//! like the runtime VM. A build must not half-succeed.

const std = @import("std");

/// Hand-declared Lua 5.4 C API — just the slice the extractor touches
/// (the vm.zig pattern; `lua_State` stays opaque).
const c = struct {
    pub const State = opaque {};
    /// lua_KFunction — never used (no continuations), but lua_pcallk's
    /// ABI wants the parameter.
    pub const KFn = *const fn (?*State, c_int, isize) callconv(.c) c_int;

    pub const LUA_OK: c_int = 0;

    pub extern fn luaL_newstate() ?*State;
    pub extern fn luaL_openlibs(L: ?*State) void;
    pub extern fn lua_close(L: ?*State) void;

    pub extern fn luaL_loadbufferx(L: ?*State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int;
    pub extern fn lua_pcallk(L: ?*State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?KFn) c_int;

    pub extern fn lua_settop(L: ?*State, idx: c_int) void;
    pub extern fn lua_createtable(L: ?*State, narr: c_int, nrec: c_int) void;
    pub extern fn lua_pushlstring(L: ?*State, s: [*]const u8, len: usize) [*]const u8;
    pub extern fn lua_getglobal(L: ?*State, name: [*:0]const u8) c_int;
    pub extern fn lua_setglobal(L: ?*State, name: [*:0]const u8) void;
    pub extern fn lua_setfield(L: ?*State, idx: c_int, k: [*:0]const u8) void;
    pub extern fn lua_tolstring(L: ?*State, idx: c_int, len: ?*usize) ?[*]const u8;
    pub extern fn lua_setupvalue(L: ?*State, funcindex: c_int, n: c_int) ?[*:0]const u8;
};

const prelude_source = @embedFile("declare_prelude.lua");

/// Longest accepted script path for the "@<path>" chunkname buffer (error
/// locations lose their tail beyond it — same cap spirit as vm.zig).
const CHUNKNAME_CAP = 256;

/// One script to scan: `path` names it in errors and in the emitted
/// chunkname; `source` is the chunk text.
pub const Input = struct {
    path: []const u8,
    source: []const u8,
};

/// Either the schema JSON (one compact line, no trailing newline) or the
/// first failure, as a printable file-and-line bearing message. The active
/// slice is owned by the caller (allocated with the `run` allocator).
pub const Outcome = union(enum) {
    schema: []u8,
    failure: []u8,

    pub fn deinit(self: Outcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .schema, .failure => |s| allocator.free(s),
        }
    }
};

pub const Error = error{
    /// luaL_newstate failed (OOM inside Lua).
    LuaStateInit,
    /// The embedded declare prelude failed to load or run — an internal
    /// bug in this tool, never a user-script problem.
    DeclarePrelude,
    OutOfMemory,
};

/// Message + pop for the error value a failed load/pcall left on top.
fn topError(L: ?*c.State, buf: []u8) []const u8 {
    var len: usize = 0;
    const msg = c.lua_tolstring(L, -1, &len);
    const text: []const u8 = if (msg) |m| m[0..len] else "(non-string error)";
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    c.lua_settop(L, -2);
    return buf[0..n];
}

/// Run every input's chunk body through the declare stub and return the
/// schema JSON — or the first failure. See the module doc for semantics.
pub fn run(allocator: std.mem.Allocator, inputs: []const Input) Error!Outcome {
    const L = c.luaL_newstate() orelse return error.LuaStateInit;
    defer c.lua_close(L);
    // Full stdlib for the PRELUDE only — scripts never see it (their
    // private _ENV below has no stdlib fallback).
    c.luaL_openlibs(L);

    // Install the declare prelude in the real globals.
    if (c.luaL_loadbufferx(L, prelude_source.ptr, prelude_source.len, "@labelle/declare_prelude.lua", "t") != c.LUA_OK)
        return error.DeclarePrelude;
    if (c.lua_pcallk(L, 0, 0, 0, 0, null) != c.LUA_OK)
        return error.DeclarePrelude;

    var err_buf: [2048]u8 = undefined;
    for (inputs) |input| {
        // Stamp the current file for the prelude's duplicate-declaration
        // attribution (the vm.zig current-script pattern).
        _ = c.lua_pushlstring(L, input.path.ptr, input.path.len);
        c.lua_setglobal(L, "__DECLARE_FILE");

        // Chunkname "@<path>" so compile errors and error() positions read
        // "<path>:<line>".
        var namebuf: [CHUNKNAME_CAP]u8 = undefined;
        namebuf[0] = '@';
        const n = @min(input.path.len, namebuf.len - 2);
        @memcpy(namebuf[1 .. 1 + n], input.path[0..n]);
        namebuf[1 + n] = 0;
        const chunkname: [*:0]const u8 = @ptrCast(&namebuf);

        if (c.luaL_loadbufferx(L, input.source.ptr, input.source.len, chunkname, "t") != c.LUA_OK) {
            const msg = topError(L, &err_buf);
            return .{ .failure = try std.fmt.allocPrint(
                allocator,
                "labelle-declare: {s}: {s}",
                .{ input.path, msg },
            ) };
        }

        // env = { labelle = __declare_stub } — the chunk's whole world.
        // Fresh per chunk so top-level definitions (init/update/...) stay
        // isolated, exactly like the runtime VM's per-script envs.
        c.lua_createtable(L, 0, 4); // [chunk, env]
        _ = c.lua_getglobal(L, "__declare_stub"); // [chunk, env, stub]
        c.lua_setfield(L, -2, "labelle"); // [chunk, env]
        if (c.lua_setupvalue(L, -2, 1) == null) {
            // Unreachable for main chunks (they always have _ENV); drop
            // the unconsumed env rather than corrupting the stack.
            c.lua_settop(L, -2);
        }

        if (c.lua_pcallk(L, 0, 0, 0, 0, null) != c.LUA_OK) {
            const msg = topError(L, &err_buf);
            return .{ .failure = try std.fmt.allocPrint(
                allocator,
                "labelle-declare: {s}: {s}",
                .{ input.path, msg },
            ) };
        }
    }

    // All chunks ran clean: pull the accumulated schema out.
    _ = c.lua_getglobal(L, "__declare_emit"); // [fn]
    if (c.lua_pcallk(L, 0, 1, 0, 0, null) != c.LUA_OK)
        return error.DeclarePrelude;
    var len: usize = 0;
    const json = c.lua_tolstring(L, -1, &len) orelse return error.DeclarePrelude;
    const out = try allocator.dupe(u8, json[0..len]);
    c.lua_settop(L, -2);
    return .{ .schema = out };
}
