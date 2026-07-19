//! Dev-experience suite (labelle-engine#740): hot reload, the update
//! error throttle, and the sandbox-by-construction pins. Compiled into
//! EVERY language binary (tests/root.zig includes it unconditionally);
//! tests gate themselves comptime on the language family — the VM family
//! (lua/ruby/typescript) exercises reload + throttle end to end, the
//! native family pins the explicit reload refusal. The watcher's own
//! filesystem behavior (pure Zig, language-free) rides the lua binary
//! only.
//!
//! See tests/root.zig for the linking model and hygiene notes shared by
//! every suite.

const std = @import("std");
const scripting = @import("labelle_scripting");
const mock = @import("mock_world.zig");
const watch = scripting.watch;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const is_vm_family = switch (scripting.language) {
    .lua, .ruby, .typescript => true,
    else => false,
};

/// Reset ALL global state (the other suites' fresh(), plus the
/// hot-reload glue: registry cleared FIRST so freeing reload-owned
/// sources can't leave dangling registry entries).
fn fresh() void {
    scripting.Controller.deinit();
    scripting.clearScripts();
    scripting.hot_reload.reset();
    mock.reset();
}

test "supports_reload is exactly the VM family" {
    try expectEqual(is_vm_family, scripting.supports_reload);
}

// ── watcher (lua binary only — pure fs code, one mirror is coverage) ───

test "stemOf mirrors the assembler's registered-stem rule" {
    if (scripting.language != .lua) return error.SkipZigTest;
    try expectEqualStrings("spawner", watch.stemOf("10_spawner.lua", ".lua"));
    try expectEqualStrings("spawner", watch.stemOf("spawner.lua", ".lua"));
    try expectEqualStrings("10spawner", watch.stemOf("10spawner.lua", ".lua"));
    try expectEqualStrings("hunger_controller", watch.stemOf("20_hunger_controller.rb", ".rb"));
    try expectEqualStrings("_x", watch.stemOf("_x.js", ".js"));
}

test "watcher: silent baseline, rewrite reported once, new file reported, deletion tolerated" {
    if (scripting.language != .lua) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "10_mover.lua", .data = "-- v1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "not a script" });

    var w = watch.Watcher.init(io, tmp.dir, ".lua");
    var changes: [8]watch.Change = undefined;

    // First poll primes the baseline: disk state at watch start IS the
    // built-in state — nothing to report.
    try expectEqual(@as(usize, 0), w.poll(&changes));

    // A rewrite (different size — mtime granularity can't hide it)
    // reports exactly once, under the registered-stem name.
    try tmp.dir.writeFile(io, .{ .sub_path = "10_mover.lua", .data = "-- v2 with a longer body" });
    try expectEqual(@as(usize, 1), w.poll(&changes));
    try expectEqualStrings("mover", changes[0].name);
    try expectEqualStrings("10_mover.lua", changes[0].file);
    try expectEqual(@as(usize, 0), w.poll(&changes));

    // A NEW matching file after the baseline is a change; the filtered
    // extension stays invisible throughout.
    try tmp.dir.writeFile(io, .{ .sub_path = "helper.lua", .data = "-- born late" });
    try expectEqual(@as(usize, 1), w.poll(&changes));
    try expectEqualStrings("helper", changes[0].name);

    // Deletion drops tracking silently (nothing sane to unload)…
    try tmp.dir.deleteFile(io, "helper.lua");
    try expectEqual(@as(usize, 0), w.poll(&changes));
    // …and a restored file re-reports as new.
    try tmp.dir.writeFile(io, .{ .sub_path = "helper.lua", .data = "-- reborn, different size" });
    try expectEqual(@as(usize, 1), w.poll(&changes));
    try expectEqualStrings("helper", changes[0].name);
}

test "watcher overflow is lossless: a bulk save drains across polls" {
    if (scripting.language != .lua) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // 20 scripts on disk, a 16-slot report buffer (the pump's own size).
    var namebuf: [32]u8 = undefined;
    for (0..20) |i| {
        const name = try std.fmt.bufPrint(&namebuf, "f{d:0>2}.lua", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "-- a" });
    }
    var w = watch.Watcher.init(io, tmp.dir, ".lua");
    var changes: [16]watch.Change = undefined;
    try expectEqual(@as(usize, 0), w.poll(&changes)); // baseline

    // Bulk save/checkout: all 20 change at once. The surplus keeps its
    // stale baseline (no silent drop) and surfaces on the next poll.
    for (0..20) |i| {
        const name = try std.fmt.bufPrint(&namebuf, "f{d:0>2}.lua", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "-- bigger body v2" });
    }
    try expectEqual(@as(usize, 16), w.poll(&changes));
    try expectEqual(@as(usize, 4), w.poll(&changes));
    try expectEqual(@as(usize, 0), w.poll(&changes));
}

// ── reload seam (per family) ───────────────────────────────────────────

/// Per-language devx scripts: v1/v2 for the reload tests (same shape —
/// an init log, an update log, one `devx_ping` handler registered FROM
/// init, the documented pattern the reload lifecycle must preserve), a
/// broken-update script + its fix for the throttle test, and a
/// late-born script for watch discovery. Log-only on purpose: behavior
/// visibility without dragging each language's entity API in.
const src = switch (scripting.language) {
    .lua => struct {
        const ext = ".lua";
        const v1: [:0]const u8 =
            \\function init()
            \\    labelle.log("devx init ran")
            \\    labelle.on("devx_ping", function(ev) labelle.log("devx v1 ping") end)
            \\end
            \\function update(dt) labelle.log("devx v1 update") end
        ;
        const v2: [:0]const u8 =
            \\function init()
            \\    labelle.log("devx init ran")
            \\    labelle.on("devx_ping", function(ev) labelle.log("devx v2 ping") end)
            \\end
            \\function update(dt) labelle.log("devx v2 update") end
        ;
        const boom: [:0]const u8 =
            \\function update(dt) error("devx boom") end
        ;
        const boom_fixed: [:0]const u8 =
            \\function update(dt) labelle.log("devx fixed") end
        ;
        const late: [:0]const u8 =
            \\function init() labelle.log("devx late init") end
            \\function update(dt) labelle.log("devx late update") end
        ;
        const broken_syntax: [:0]const u8 = "function (";
    },
    .ruby => struct {
        const ext = ".rb";
        const v1: [:0]const u8 =
            \\def init
            \\  Labelle.log("devx init ran")
            \\  Labelle.on("devx_ping") { |ev| Labelle.log("devx v1 ping") }
            \\end
            \\def update(dt)
            \\  Labelle.log("devx v1 update")
            \\end
        ;
        const v2: [:0]const u8 =
            \\def init
            \\  Labelle.log("devx init ran")
            \\  Labelle.on("devx_ping") { |ev| Labelle.log("devx v2 ping") }
            \\end
            \\def update(dt)
            \\  Labelle.log("devx v2 update")
            \\end
        ;
        const boom: [:0]const u8 =
            \\def update(dt)
            \\  raise "devx boom"
            \\end
        ;
        const boom_fixed: [:0]const u8 =
            \\def update(dt)
            \\  Labelle.log("devx fixed")
            \\end
        ;
        const late: [:0]const u8 =
            \\def init
            \\  Labelle.log("devx late init")
            \\end
            \\def update(dt)
            \\  Labelle.log("devx late update")
            \\end
        ;
        const broken_syntax: [:0]const u8 = "def (";
    },
    .typescript => struct {
        const ext = ".js";
        const v1: [:0]const u8 =
            \\export function init() {
            \\  labelle.log("devx init ran");
            \\  labelle.on("devx_ping", (ev) => { labelle.log("devx v1 ping"); });
            \\}
            \\export function update(dt) { labelle.log("devx v1 update"); }
        ;
        const v2: [:0]const u8 =
            \\export function init() {
            \\  labelle.log("devx init ran");
            \\  labelle.on("devx_ping", (ev) => { labelle.log("devx v2 ping"); });
            \\}
            \\export function update(dt) { labelle.log("devx v2 update"); }
        ;
        const boom: [:0]const u8 =
            \\export function update(dt) { throw new Error("devx boom"); }
        ;
        const boom_fixed: [:0]const u8 =
            \\export function update(dt) { labelle.log("devx fixed"); }
        ;
        const late: [:0]const u8 =
            \\export function init() { labelle.log("devx late init"); }
            \\export function update(dt) { labelle.log("devx late update"); }
        ;
        const broken_syntax: [:0]const u8 = "function (";
    },
    else => struct {
        const ext = "";
    },
};

test "reloadScript refuses on the native family (compiled code cannot re-eval)" {
    if (comptime is_vm_family) return error.SkipZigTest;
    fresh();
    try expect(!scripting.reloadScript("anything", "x = 1"));
    try expect(mock.logsContain("hot reload is not supported"));
    // And it registered nothing — sources are refused wholesale there.
    try expectEqual(@as(usize, 0), scripting.registeredScriptCount());
}

test "reloadScript replays the lifecycle: behavior swaps, init re-runs, no handler pileup or loss" {
    if (comptime !is_vm_family) return error.SkipZigTest;
    fresh();
    scripting.registerScript("counter", src.v1);
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    try expect(mock.logsContain("devx v1 update"));
    try expectEqual(@as(usize, 1), mock.logCount("devx init ran"));

    try expect(scripting.reloadScript("counter", src.v2));
    scripting.Controller.tick(.{}, 0.016);

    // New behavior, same VM, same tick loop.
    try expect(mock.logsContain("devx v2 update"));
    // The reload lifecycle REPLAYS init() (the dev-mode contract: init
    // is a documented place to subscribe, and skipping it would silently
    // drop those subscriptions) — exactly once per reload.
    try expectEqual(@as(usize, 2), mock.logCount("devx init ran"));

    // The old incarnation's handlers were purged BEFORE the new init
    // re-registered: one ping fires exactly one v2 reaction — the
    // init-registered subscription survives reload without stacking.
    mock.hostEmit("devx_ping", "{}");
    scripting.Controller.tick(.{}, 0.016);
    try expectEqual(@as(usize, 0), mock.logCount("devx v1 ping"));
    try expectEqual(@as(usize, 1), mock.logCount("devx v2 ping"));
}

test "reloading a boot-broken script runs init once fixed" {
    if (comptime !is_vm_family) return error.SkipZigTest;
    fresh();
    scripting.registerScript("counter", src.broken_syntax);
    try scripting.Controller.setup(.{}); // load fails, logged, evicted
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    try expect(!mock.logsContain("devx init ran"));

    // The fix-and-save loop: the reload replays the full lifecycle.
    try expect(scripting.reloadScript("counter", src.v1));
    try expectEqual(@as(usize, 1), mock.logCount("devx init ran"));
    scripting.Controller.tick(.{}, 0.016);
    try expect(mock.logsContain("devx v1 update"));
}

test "reload state machine: a bad save halts the script; the next good save replays init ONCE" {
    if (comptime !is_vm_family) return error.SkipZigTest;
    fresh();
    scripting.registerScript("counter", src.v1);
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    scripting.Controller.tick(.{}, 0.016);
    try expectEqual(@as(usize, 1), mock.logCount("devx init ran"));
    const v1_updates = mock.logCount("devx v1 update");

    // Bad save: reload fails, and the script goes SILENT (running
    // half-old code with its handlers purged would be worse than none).
    try expect(!scripting.reloadScript("counter", src.broken_syntax));
    scripting.Controller.tick(.{}, 0.016);
    scripting.Controller.tick(.{}, 0.016);
    try expectEqual(v1_updates, mock.logCount("devx v1 update"));
    try expectEqual(@as(usize, 1), mock.logCount("devx init ran"));

    // Good save: ONE lifecycle replay (the failed save contributed no
    // init), new behavior ticks, the init-registered handler answers.
    try expect(scripting.reloadScript("counter", src.v2));
    try expectEqual(@as(usize, 2), mock.logCount("devx init ran"));
    scripting.Controller.tick(.{}, 0.016);
    try expect(mock.logsContain("devx v2 update"));
    mock.hostEmit("devx_ping", "{}");
    scripting.Controller.tick(.{}, 0.016);
    try expectEqual(@as(usize, 1), mock.logCount("devx v2 ping"));
}

test "hot reload end to end: edit on disk, pump, behavior changes; a new file self-registers" {
    if (comptime !is_vm_family) return error.SkipZigTest;
    fresh();
    defer scripting.hot_reload.reset();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // The production shape: the built game registered the embedded v1,
    // and the same source sits on disk in the watched dir.
    const file = "10_counter" ++ src.ext;
    try tmp.dir.writeFile(io, .{ .sub_path = file, .data = src.v1 });
    scripting.registerScript("counter", src.v1);
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    try scripting.hot_reload.watchOpenedDir(io, std.testing.allocator, tmp.dir);
    try expectEqual(@as(usize, 0), scripting.hot_reload.pump()); // baseline

    scripting.Controller.tick(.{}, 0.016);
    try expect(mock.logsContain("devx v1 update"));

    // The acceptance loop: save the file while the game runs…
    try tmp.dir.writeFile(io, .{ .sub_path = file, .data = src.v2 });
    try expectEqual(@as(usize, 1), scripting.hot_reload.pump());
    scripting.Controller.tick(.{}, 0.016);
    // …and behavior updated without restart (init replayed once, per
    // the reload lifecycle).
    try expect(mock.logsContain("devx v2 update"));
    try expectEqual(@as(usize, 2), mock.logCount("devx init ran"));

    // A file born after watch start registers, loads and inits.
    const late_file = "99_late" ++ src.ext;
    try tmp.dir.writeFile(io, .{ .sub_path = late_file, .data = src.late });
    try expectEqual(@as(usize, 1), scripting.hot_reload.pump());
    try expectEqual(@as(usize, 1), mock.logCount("devx late init"));
    scripting.Controller.tick(.{}, 0.016);
    try expect(mock.logsContain("devx late update"));
}

test "hot reload pumps off the Controller tick cadence (dev builds)" {
    if (comptime !is_vm_family) return error.SkipZigTest;
    fresh();
    defer scripting.hot_reload.reset();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const file = "10_counter" ++ src.ext;
    try tmp.dir.writeFile(io, .{ .sub_path = file, .data = src.v1 });
    scripting.registerScript("counter", src.v1);
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try scripting.hot_reload.watchOpenedDir(io, std.testing.allocator, tmp.dir);

    // Tick 1 polls (countdown starts spent) — that's the baseline prime.
    scripting.Controller.tick(.{}, 0.016);
    try tmp.dir.writeFile(io, .{ .sub_path = file, .data = src.v2 });
    // Within the next poll_interval_ticks the edit lands via tick alone.
    for (0..scripting.hot_reload.poll_interval_ticks + 1) |_| {
        scripting.Controller.tick(.{}, 0.016);
    }
    try expect(mock.logsContain("devx v2 update"));
}

test "ruby: a script discovered mid-run inits BEFORE its controllers set up" {
    // The boot order — every init, then controller setup — must hold for
    // the reload lifecycle too: a controller's setup may depend on
    // entities/state the script's init seeds (finding: labelle-scripting
    // PR #47 review). Pinned by log ORDER on the new-file-discovered
    // path (reloadScript on a never-registered name — what the watcher
    // does for a file born mid-run).
    if (scripting.language != .ruby) return error.SkipZigTest;
    fresh();
    try scripting.Controller.setup(.{}); // boot sweep runs (no scripts)
    defer scripting.Controller.deinit();

    try expect(scripting.reloadScript("seeded",
        \\def init
        \\  Labelle.log("seed init ran")
        \\end
        \\class DevxSeedController < Labelle::Controller
        \\  def setup
        \\    log("seed controller setup")
        \\  end
        \\
        \\  def tick(dt)
        \\  end
        \\end
    ));
    const init_idx = mock.logIndexOf("seed init ran") orelse return error.TestExpectedLog;
    const setup_idx = mock.logIndexOf("seed controller setup") orelse return error.TestExpectedLog;
    try expect(init_idx < setup_idx);
    scripting.Controller.tick(.{}, 0.016); // the fresh controller ticks clean
}

// ── error-UX throttle ──────────────────────────────────────────────────

test "update throttle: three consecutive tracebacks, then one attempt per stride; reload restores cadence" {
    if (comptime !is_vm_family) return error.SkipZigTest;
    fresh();
    scripting.registerScript("boom", src.boom);
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();

    // threshold(3) failures log at full cadence; the announcement fires
    // once; then one attempt (tick 63 = 3 + stride) inside the window.
    const total = 3 + scripting.update_throttle_stride;
    for (0..total) |_| scripting.Controller.tick(.{}, 0.016);
    try expectEqual(@as(usize, 4), mock.logCount("devx boom"));
    try expectEqual(@as(usize, 1), mock.logCount("throttling to one attempt"));

    // A reload clears the episode: the fixed script runs the very next
    // tick, full cadence.
    try expect(scripting.reloadScript("boom", src.boom_fixed));
    scripting.Controller.tick(.{}, 0.016);
    scripting.Controller.tick(.{}, 0.016);
    try expectEqual(@as(usize, 2), mock.logCount("devx fixed"));
    // No further boom logs after the fix.
    try expectEqual(@as(usize, 4), mock.logCount("devx boom"));
}

// ── sandbox-by-construction pins (see src/sandbox.zig) ─────────────────

test "sandbox profile is off by default" {
    // These binaries carry the DEFAULT params module (no `sandbox` decl):
    // current behavior unchanged — the profile only exists where a
    // project opts in (tests/sandbox_root.zig is the opted-in binary).
    try expect(!scripting.sandbox_enabled);
}

test "lua default profile keeps the full stdlib (io/os present)" {
    if (scripting.language != .lua) return error.SkipZigTest;
    fresh();
    scripting.registerScript("stdlib_probe",
        \\function init()
        \\    labelle.log("lua stdlib: io=" .. type(io) .. " os=" .. type(os))
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expect(mock.logsContain("lua stdlib: io=table os=table"));
}

test "ruby is sandboxed by construction: no File/IO/Dir in the vendored gem set" {
    if (scripting.language != .ruby) return error.SkipZigTest;
    fresh();
    scripting.registerScript("fs_probe",
        \\def init
        \\  fs = []
        \\  fs << "File" if Object.const_defined?(:File)
        \\  fs << "IO" if Object.const_defined?(:IO)
        \\  fs << "Dir" if Object.const_defined?(:Dir)
        \\  if fs.empty?
        \\    Labelle.log("ruby fs: none reachable")
        \\  else
        \\    Labelle.log("ruby fs: LEAK " + fs.join(","))
        \\  end
        \\end
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expect(mock.logsContain("ruby fs: none reachable"));
    try expect(!mock.logsContain("ruby fs: LEAK"));
}

test "typescript is sandboxed by construction: no os/std/require host bindings" {
    if (scripting.language != .typescript) return error.SkipZigTest;
    fresh();
    scripting.registerScript("fs_probe",
        \\export function init() {
        \\  labelle.log("ts fs: " + typeof os + " " + typeof std + " " + typeof require);
        \\}
    );
    try scripting.Controller.setup(.{});
    defer scripting.Controller.deinit();
    try expect(mock.logsContain("ts fs: undefined undefined undefined"));
}
