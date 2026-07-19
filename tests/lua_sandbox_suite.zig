//! The lua mod-sandbox profile (labelle-engine#740) driven end to end:
//! filesystem/OS access is unreachable, everything else — the safe
//! stdlib subset, the whole labelle script API, the error UX — works
//! exactly as in the default profile. See src/sandbox.zig for the
//! mechanism (safe-lib subset instead of luaL_openlibs) and
//! tests/sandbox_root.zig for why this rides its own test binary.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

fn fresh() void {
    scripting.Controller.deinit();
    scripting.clearScripts();
    mock.reset();
}

fn expectComponent(id: u64, name: []const u8, expected: []const u8) !void {
    const got = mock.componentJson(id, name) orelse {
        std.debug.print("missing component '{s}' on entity {d}\n", .{ name, id });
        return error.TestExpectedComponent;
    };
    try expectEqualStrings(expected, got);
}

test "this binary IS the sandbox profile" {
    try expect(scripting.sandbox_enabled);
}

test "filesystem and OS access are unreachable" {
    fresh();
    // Every fs/os door the default profile has, probed from script land:
    // the io and os tables, package/require (filesystem module search),
    // the base library's dofile/loadfile, and the debug library (whose
    // getregistry would reach package.loaded and beyond).
    scripting.registerScript("fs_probe",
        \\function init()
        \\    local absent = { "io", "os", "require", "dofile", "loadfile", "package", "debug" }
        \\    for _, name in ipairs(absent) do
        \\        if _G[name] ~= nil then
        \\            labelle.log("sandbox LEAK: " .. name)
        \\            return
        \\        end
        \\    end
        \\    labelle.log("sandbox: fs/os unreachable")
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expect(mock.logsContain("sandbox: fs/os unreachable"));
    try expect(!mock.logsContain("sandbox LEAK"));
}

test "sandboxed load is text-only: binary chunks refused, text chunks work" {
    fresh();
    // "\27" is LUA_SIGNATURE's first byte — every precompiled chunk
    // starts with it, and text-mode load refuses it up front ("attempt
    // to load a binary chunk"). The probe covers the default mode, an
    // explicit "b" request (the wrapper pins mode to "t" regardless),
    // and that plain text chunks still compile and run.
    scripting.registerScript("load_probe",
        \\function init()
        \\    local f, err = load("\27Lua bytecode")
        \\    local fb = load("\27Lua bytecode", "bin", "b")
        \\    local g = load("return 41 + 1")
        \\    if f == nil and err ~= nil and fb == nil and g ~= nil and g() == 42 then
        \\        labelle.log("sandbox: binary chunks refused, text load ok")
        \\    else
        \\        labelle.log("sandbox load LEAK")
        \\    end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expect(mock.logsContain("sandbox: binary chunks refused, text load ok"));
    try expect(!mock.logsContain("sandbox load LEAK"));
}

test "the safe stdlib subset is intact" {
    fresh();
    scripting.registerScript("stdlib_probe",
        \\function init()
        \\    local co = coroutine.create(function() coroutine.yield(7) end)
        \\    local _, y = coroutine.resume(co)
        \\    local t = {}
        \\    table.insert(t, math.floor(2.9))
        \\    labelle.log(string.format("sandbox stdlib: %d %d %s %d",
        \\        t[1], y, utf8.char(0x2713), select("#", 1, 2, 3)))
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expect(mock.logsContain("sandbox stdlib: 2 7 ✓ 3"));
}

test "the labelle script API works sandboxed: the behavior script end to end" {
    // The default-profile suite's flagship test, byte-identical
    // assertions: the sandbox must cost scripts NOTHING but fs/os.
    fresh();
    scripting.registerScript("behavior", @embedFile("lua/behavior.lua"));
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try expectComponent(1, "Position", "{\"x\":0,\"y\":0}");
    try expect(mock.logsContain("lua: player 1 ready"));

    var buf: [32]u8 = undefined;
    for (1..6) |n| {
        const payload = try std.fmt.bufPrint(&buf, "{{\"n\":{d}}}", .{n});
        mock.hostEmit("tick_started", payload);
        scripting.Controller.tick(.{}, 1.0 / 60.0);
    }

    try expectComponent(1, "Position", "{\"x\":50,\"y\":0}");
    try expectComponent(1, "TickLog", "{\"last\":4}");
    try expectComponent(2, "Bullet", "{\"vx\":0,\"vy\":-500}");
    try expect(mock.eventsContain("bullet_spawned {\"owner\":1}"));
}

test "error UX survives the sandbox (tracebacks need no debug library)" {
    fresh();
    scripting.registerScript("exploder",
        \\function update(dt)
        \\    error("sandboxed boom")
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    scripting.Controller.tick(.{}, 0.016);
    // luaL_traceback is the C entry behind debug.traceback — the trace
    // works with the debug LIBRARY never opened, and the tick survived.
    try expect(mock.logsContain("sandboxed boom"));
    try expect(mock.logsContain("stack traceback:"));
    scripting.Controller.tick(.{}, 0.016);
}
