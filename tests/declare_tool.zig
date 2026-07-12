//! labelle-declare goldens — the declare-mode extractor driven in-process
//! (tools/declare/extract.zig via the `declare_core` named module; the lua
//! objects come from the `labelle_scripting` module already linked into
//! this test binary, so nothing spawns).
//!
//! What's pinned here IS the runner↔assembler contract (assembler#585):
//! the exact schema JSON for a representative declaration set, the
//! declaration-order / sorted-fields determinism rules, the "only the
//! chunk body runs, only `labelle` is in scope" execution model, and the
//! file-and-name-bearing failure text for every malformed-spec class.

const std = @import("std");
const extract = @import("declare_core");
const cross = @import("declare_cross_golden.zig");

const testing = std.testing;
const expect = testing.expect;
const expectEqualStrings = testing.expectEqualStrings;

/// Run the extractor over `inputs` and assert the schema JSON byte-exact.
fn expectSchema(inputs: []const extract.Input, expected: []const u8) !void {
    const outcome = try extract.run(testing.allocator, inputs);
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .schema => |json| try expectEqualStrings(expected, json),
        .failure => |msg| {
            std.debug.print("expected a schema, got failure:\n  {s}\n", .{msg});
            return error.TestUnexpectedFailure;
        },
    }
}

/// Run the extractor over `inputs`, expect a failure, and assert every
/// `needle` appears in the message (file names, component/field names).
fn expectFailure(inputs: []const extract.Input, needles: []const []const u8) !void {
    const outcome = try extract.run(testing.allocator, inputs);
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .schema => |json| {
            std.debug.print("expected a failure, got schema:\n  {s}\n", .{json});
            return error.TestExpectedFailure;
        },
        .failure => |msg| {
            for (needles) |needle| {
                if (std.mem.indexOf(u8, msg, needle) == null) {
                    std.debug.print("missing \"{s}\" in failure:\n  {s}\n", .{ needle, msg });
                    return error.TestMissingNeedle;
                }
            }
        },
    }
}

test "golden: every v1-inferable type across two files, declaration order + sorted fields" {
    // Inference matrix: float→f32 (1.0 IS a float in Lua 5.4), integer→i32,
    // boolean→bool, string→str, {x=,y=}→vec2. Components emit in
    // DECLARATION order (argv order, then top-to-bottom); fields emit
    // SORTED (pairs() order over the spec is unspecified). Float defaults
    // always carry their floatness ("1.0", "4.0"); the vec2's y stays the
    // integer it was declared as.
    try expectSchema(&.{
        .{
            .path = "lua/hunger.lua",
            .source =
            \\labelle.component("Hunger", { level = 1.0, starving = false })
            \\labelle.component("Wallet", { coins = 250 })
            ,
        },
        .{
            .path = "lua/ai/guard.lua",
            // `local Patrol = ...`: the declare stub returns the same ref
            // shape the runtime does, so ref-binding chunk scope is legal
            // in both modes (no stdlib here to assert with — that world
            // belongs to the runtime tests).
            .source =
            \\local Patrol = labelle.component("Patrol", {
            \\  speed = 12.5,
            \\  home = { x = 4.0, y = -2 },
            \\  label = "guard \"one\"",
            \\  active = true,
            \\}, { persist = "transient" })
            ,
        },
    },
        \\{"components":[{"name":"Hunger","persist":"persistent","fields":[{"name":"level","type":"f32","default":1.0},{"name":"starving","type":"bool","default":false}]},{"name":"Wallet","persist":"persistent","fields":[{"name":"coins","type":"i32","default":250}]},{"name":"Patrol","persist":"transient","fields":[{"name":"active","type":"bool","default":true},{"name":"home","type":"vec2","default":{"x":4.0,"y":-2}},{"name":"label","type":"str","default":"guard \"one\""},{"name":"speed","type":"f32","default":12.5}]}]}
    );
}

test "golden: a field-less marker component and a declaration-free script" {
    // {} declares a zero-field marker; a script with no declarations
    // contributes nothing; NO scripts declaring → the empty schema (the
    // assembler's no-op gate keys on exactly this).
    try expectSchema(&.{
        .{ .path = "a.lua", .source = "labelle.component(\"Dead\", {}, { persist = \"transient\" })" },
        .{ .path = "b.lua", .source = "function update(dt) end" },
    },
        \\{"components":[{"name":"Dead","persist":"transient","fields":[]}]}
    );
    try expectSchema(&.{.{ .path = "b.lua", .source = "function update(dt) end" }},
        \\{"components":[]}
    );
}

test "only the chunk body runs: hooks never fire, other labelle.* are silent no-ops" {
    // init() would blow up at runtime (error + Entity/game references) —
    // declare mode never calls it. Chunk-scope labelle.on/log/array run
    // against the sentinel-returning no-op (results discarded here). The
    // declaration BELOW the no-ops still records: the whole body executes.
    try expectSchema(&.{
        .{
            .path = "spiky.lua",
            .source =
            \\labelle.on("ping", function(ev) end)
            \\labelle.log("chunk scope")
            \\labelle.array({})
            \\function init()
            \\  error("init must never run in declare mode")
            \\  Entity.new():set("X", game.query("Y"))
            \\end
            \\function update(dt) error("nor update") end
            \\labelle.component("Spiky", { n = 1 })
            ,
        },
    },
        \\{"components":[{"name":"Spiky","persist":"persistent","fields":[{"name":"n","type":"i32","default":1}]}]}
    );
}

test "duplicate declarations fail naming BOTH files" {
    try expectFailure(&.{
        .{ .path = "lua/first.lua", .source = "labelle.component(\"Hunger\", { level = 1.0 })" },
        .{ .path = "lua/second.lua", .source = "\nlabelle.component(\"Hunger\", { level = 2.0 })" },
    }, &.{
        "lua/second.lua:2", // the redeclaration site (chunkname:line)
        "duplicate component 'Hunger'",
        "first declared in lua/first.lua",
    });
}

test "malformed specs fail with file-, component- and field-bearing errors" {
    // Empty name.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"\", {})" }},
        &.{ "bad.lua:1", "non-empty component name" },
    );
    // Non-identifier name.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Hun ger\", {})" }},
        &.{ "bad.lua:1", "'Hun ger'", "not a valid identifier" },
    );
    // Missing spec table.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Hunger\")" }},
        &.{ "bad.lua:1", "'Hunger'", "spec table" },
    );
    // Unsupported field value type (functions have no schema type).
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Bad\", { cb = function() end })" }},
        &.{ "bad.lua:1", "component 'Bad' field 'cb'", "unsupported default of type function" },
    );
    // A table default that isn't the {x=,y=} vec2 shape.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Bad\", { path = { 1, 2, 3 } })" }},
        &.{ "bad.lua:1", "component 'Bad' field 'path'", "unsupported table default" },
    );
    // Integer default outside i32 (u32/entity are schema-only in v1 — no
    // lua spelling reaches them).
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Big\", { n = 3000000000 })" }},
        &.{ "bad.lua:1", "component 'Big' field 'n'", "out of i32 range" },
    );
    // Bad persist value / unknown option key.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Hunger\", {}, { persist = \"forever\" })" }},
        &.{ "bad.lua:1", "'Hunger'", "invalid persist value 'forever'" },
    );
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Hunger\", {}, { presist = \"transient\" })" }},
        &.{ "bad.lua:1", "'Hunger'", "unknown option 'presist'" },
    );
}

test "labelle.* helper results in a spec fail the build instead of silently dropping the field" {
    // `waypoints = labelle.array({})`: were the no-op to return nil, the
    // table constructor would silently DROP the key and Path would
    // validate WITHOUT the field. The no-ops return a sentinel that
    // declare_component rejects with a pointed message instead.
    try expectFailure(
        &.{.{
            .path = "lua/path.lua",
            .source = "labelle.component(\"Path\", { waypoints = labelle.array({}) })",
        }},
        &.{
            "lua/path.lua:1",
            "component 'Path' field 'waypoints'",
            "labelle.* helpers cannot be used in component specs — declare-mode fields are literals",
        },
    );
    // The sentinel is a table, so it would otherwise slip past the
    // "expects a spec table" / "options must be a table" guards that
    // catch nil — the spec and opts positions are scanned too.
    try expectFailure(
        &.{.{ .path = "lua/path.lua", .source = "labelle.component(\"Path\", labelle.array({}))" }},
        &.{ "lua/path.lua:1", "component 'Path' spec", "declare-mode fields are literals" },
    );
    try expectFailure(
        &.{.{ .path = "lua/path.lua", .source = "labelle.component(\"Path\", {}, labelle.array({}))" }},
        &.{ "lua/path.lua:1", "component 'Path' options", "declare-mode fields are literals" },
    );
}

test "float defaults must fit f32: finite-but-huge fails alongside NaN/inf; the edge passes" {
    // 1e100 / -1e100 are FINITE doubles no f32 can hold — accepting them
    // would emit impossible "f32" defaults for the assembler to codegen.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Big\", { v = 1e100 })" }},
        &.{ "bad.lua:1", "component 'Big' field 'v'", "out of f32 range" },
    );
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Big\", { v = -1e100 })" }},
        &.{ "bad.lua:1", "component 'Big' field 'v'", "out of f32 range" },
    );
    // Non-finite values keep their own error class (no math.huge in a
    // chunk — scripts have no stdlib; arithmetic reaches the same values).
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Bad\", { v = 0/0 })" }},
        &.{ "bad.lua:1", "component 'Bad' field 'v'", "non-finite" },
    );
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Bad\", { v = 1/0 })" }},
        &.{ "bad.lua:1", "component 'Bad' field 'v'", "non-finite" },
    );
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Bad\", { v = -1/0 })" }},
        &.{ "bad.lua:1", "component 'Bad' field 'v'", "non-finite" },
    );
    // 3.4e38 sits just under f32 max (3.4028235e38): still a legal
    // default, and %.14g keeps it exact.
    try expectSchema(&.{.{ .path = "edge.lua", .source = "labelle.component(\"Edge\", { v = 3.4e38 })" }},
        \\{"components":[{"name":"Edge","persist":"persistent","fields":[{"name":"v","type":"f32","default":3.4e+38}]}]}
    );
    // vec2 axes ride the same range check.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Bad\", { home = { x = 1e100, y = 0 } })" }},
        &.{ "bad.lua:1", "component 'Bad' field 'home'", "out of f32 range" },
    );
}

test "a chunk clobbering labelle.component cannot poison later chunks (fresh stub per chunk)" {
    // clobber.lua nils out `component` — on ITS private stub copy only.
    // With one shared stub table the assignment stripped the key for
    // every later chunk, whose declarations then fell through __index to
    // the silent no-op and vanished from the schema.
    try expectSchema(&.{
        .{ .path = "clobber.lua", .source = "labelle.component = nil" },
        .{ .path = "after.lua", .source = "labelle.component(\"Survivor\", { hp = 3 })" },
    },
        \\{"components":[{"name":"Survivor","persist":"persistent","fields":[{"name":"hp","type":"i32","default":3}]}]}
    );
}

test "chunk-scope code outside the labelle stub fails loudly with its location" {
    // Declare mode's world is the stub `labelle` ONLY — no stdlib, no
    // prelude globals. A chunk-scope call into anything else must fail the
    // build with the file:line, not silently skip the script.
    try expectFailure(
        &.{.{ .path = "lua/chatty.lua", .source = "print(\"hello\")" }},
        &.{ "lua/chatty.lua:1", "print" },
    );
    // Compile errors carry their location the same way.
    try expectFailure(
        &.{.{ .path = "lua/broken.lua", .source = "function (" }},
        &.{"lua/broken.lua:1"},
    );
}

test "chunk envs are isolated: one script's top-level globals never leak into the next" {
    // a.lua defines `helper` at chunk scope (landing in ITS private env);
    // b.lua calling it must find nil — same isolation the runtime VM gives
    // registered scripts.
    try expectFailure(&.{
        .{ .path = "a.lua", .source = "function helper() end\nlabelle.component(\"A\", {})" },
        .{ .path = "b.lua", .source = "helper()" },
    }, &.{ "b.lua:1", "helper" });
}

test "a component ref where an event name belongs fails at generate (the on/emit shims)" {
    // The ruby runner's codex finding (#28) exists here too:
    // `labelle.on(Worker)` — a real constant of the WRONG KIND (the
    // component ref table, not an event-name string) — used to pass a
    // blind no-op and only die at RUNTIME, where raw_event_subscribe
    // reads the name through lua_tolstring (strings and numbers only) and
    // the raise evicts the script. The declare stub's on/emit shims now
    // validate the name at generate, naming the component.
    try expectFailure(&.{.{
        .path = "scripts/bad.lua",
        .source =
        \\local Worker = labelle.component("Worker", { hp = 1 })
        \\labelle.on(Worker, function(ev) end)
        ,
    }}, &.{
        "scripts/bad.lua:2",
        "labelle.on: expected an event-name string",
        "the component 'Worker'",
    });
    try expectFailure(&.{.{
        .path = "scripts/bad.lua",
        .source =
        \\local Worker = labelle.component("Worker", { hp = 1 })
        \\labelle.emit(Worker, { amount = 1 })
        ,
    }}, &.{
        "scripts/bad.lua:2",
        "labelle.emit: expected an event-name string",
        "the component 'Worker'",
    });
    // nil rides the same rejection: an undefined global (a typo, or a
    // cross-file global — runtime script envs SHADOW _G, so those never
    // resolve there either) raises identically at runtime.
    try expectFailure(&.{.{
        .path = "scripts/bad.lua",
        .source = "labelle.on(HungerFed, function(ev) end)",
    }}, &.{ "scripts/bad.lua:1", "labelle.on: expected an event-name string", "got nil" });
    // A helper result names its own source; the runtime would raise on
    // the non-string all the same.
    try expectFailure(&.{.{
        .path = "scripts/bad.lua",
        .source = "labelle.emit(labelle.array({}))",
    }}, &.{ "scripts/bad.lua:1", "labelle.emit", "a labelle.* helper result" });
    // The shims mirror the runtime's ACCEPTANCE too, not a stricter rule:
    // the same-file event constant is the name string (the RFC line), and
    // numbers pass because lua_tolstring coerces them at runtime.
    try expectSchema(&.{.{
        .path = "scripts/ok.lua",
        .source =
        \\local HungerFeed = labelle.event("hunger__feed", {})
        \\labelle.on(HungerFeed, function(ev) end)
        \\labelle.emit(HungerFeed, { amount = 1 })
        \\labelle.on(42, function(ev) end)
        \\labelle.emit(7)
        ,
    }},
        \\{"components":[],"events":[{"name":"hunger__feed","fields":[]}]}
    );
}

test "cross-runner golden: the lua half — byte-identical to the ruby runner's schema" {
    // The other half lives in tests/declare_ruby_tool.zig (the ruby
    // binary); both assert the SAME expected literal from
    // declare_cross_golden.zig — one logical declaration set, one schema,
    // whatever the language.
    try expectSchema(
        &.{.{ .path = cross.lua_path, .source = cross.lua_source }},
        cross.expected_json,
    );
}

test "golden: events emit in their own array — no persist key, declaration order, sorted fields" {
    // labelle-engine#772: the events array trails components, carries NO
    // persist (events are never saved), and follows the same determinism
    // rules — declaration order across files, fields sorted by name.
    // labelle.id classifies u64 with default 0. (Every OTHER golden in
    // this file has no events key at all — the emitters may add it only
    // when an event was declared, or those pins break; that absence is
    // the old-assembler compat rule.)
    try expectSchema(&.{
        .{
            .path = "events/hunger__feed.lua",
            .source =
            \\HungerFeed = labelle.event("hunger__feed", {
            \\  entity = labelle.id,
            \\  amount = 0.5,
            \\})
            ,
        },
        .{ .path = "events/wave__spawned.lua", .source = "labelle.event(\"wave__spawned\", {})" },
    },
        \\{"components":[],"events":[{"name":"hunger__feed","fields":[{"name":"amount","type":"f32","default":0.5},{"name":"entity","type":"u64","default":0}]},{"name":"wave__spawned","fields":[]}]}
    );
}

test "events and components are separate namespaces: one name, both kinds, both emit" {
    // The SAME name declared as a component and as an event is legal —
    // duplicate detection is per kind — and labelle.id is a legal
    // COMPONENT field too (components gain u64 through the same marker).
    try expectSchema(&.{
        .{
            .path = "lua/hunger.lua",
            .source =
            \\labelle.component("Hunger", { level = 1.0, owner = labelle.id })
            \\labelle.event("Hunger", { entity = labelle.id })
            ,
        },
    },
        \\{"components":[{"name":"Hunger","persist":"persistent","fields":[{"name":"level","type":"f32","default":1.0},{"name":"owner","type":"u64","default":0}]}],"events":[{"name":"Hunger","fields":[{"name":"entity","type":"u64","default":0}]}]}
    );
}

test "duplicate event declarations fail naming BOTH files" {
    try expectFailure(&.{
        .{ .path = "events/first.lua", .source = "labelle.event(\"hunger__feed\", {})" },
        .{ .path = "events/second.lua", .source = "\nlabelle.event(\"hunger__feed\", {})" },
    }, &.{
        "events/second.lua:2", // the redeclaration site (chunkname:line)
        "duplicate event 'hunger__feed'",
        "first declared in events/first.lua",
    });
}

test "malformed event declarations fail with file- and event-bearing errors" {
    // Empty name.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.event(\"\", {})" }},
        &.{ "bad.lua:1", "non-empty event name" },
    );
    // Non-identifier name (double underscores ARE legal — hunger__feed
    // passes the goldens above; a space does not).
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.event(\"hunger feed\", {})" }},
        &.{ "bad.lua:1", "'hunger feed'", "not a valid identifier" },
    );
    // Missing spec table — payloadless events spell it {} explicitly.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.event(\"tick\")" }},
        &.{ "bad.lua:1", "'tick'", "spec table" },
    );
    // A third argument is not a persist knob: events take no options.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.event(\"tick\", {}, { persist = \"transient\" })" }},
        &.{ "bad.lua:1", "'tick'", "takes no options (events are not persisted)" },
    );
    // …and neither is a FOURTH: the recorder is vararg so extras can't
    // slip past a fixed third param unseen.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.event(\"tick\", {}, nil, { persist = \"transient\" })" }},
        &.{ "bad.lua:1", "'tick'", "takes no options (events are not persisted)" },
    );
    // One EXPLICIT nil third arg stays legal — ruby's fixed-arity
    // `opts = nil` signature cannot distinguish it from the two-arg
    // call, so cross-runner parity keeps it callable here too.
    try expectSchema(&.{.{ .path = "ok.lua", .source = "labelle.event(\"tick\", {}, nil)" }},
        \\{"components":[],"events":[{"name":"tick","fields":[]}]}
    );
    // Unsupported field value type.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.event(\"bad\", { cb = function() end })" }},
        &.{ "bad.lua:1", "event 'bad' field 'cb'", "unsupported default of type function" },
    );
    // The no-op sentinel is rejected in spec and field positions, with
    // the message naming the EVENT DSL.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.event(\"bad\", labelle.array({}))" }},
        &.{ "bad.lua:1", "event 'bad' spec", "cannot be used in event specs — declare-mode fields are literals" },
    );
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.event(\"bad\", { w = labelle.array({}) })" }},
        &.{ "bad.lua:1", "event 'bad' field 'w'", "cannot be used in event specs" },
    );
}

test "labelle.id is a value: calling it fails pointedly, and it is no spec" {
    // v1 has no id(value) constructor — `labelle.id(42)` must name the
    // mistake, not classify garbage (ids always default 0).
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.component(\"Bad\", { owner = labelle.id(42) })" }},
        &.{ "bad.lua:1", "labelle.id", "write entity = labelle.id" },
    );
    // In spec position the marker is a function, so the existing shape
    // guard names the real problem.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.event(\"bad\", labelle.id)" }},
        &.{ "bad.lua:1", "'bad'", "spec table" },
    );
    // Nested inside a vec2-shaped table: v1 ids are scalar-only.
    try expectFailure(
        &.{.{ .path = "bad.lua", .source = "labelle.event(\"bad\", { at = { x = labelle.id, y = 0 } })" }},
        &.{ "bad.lua:1", "event 'bad' field 'at'", "unsupported table default" },
    );
}

test "the event field cap fails on the declaration line: 33 rejected, 32 passes" {
    // Event payloads share the 32-field ceiling the ruby runner inherits
    // from its view fast path — one schema, whatever the language, so the
    // lua runner must reject the same declaration the ruby runner would
    // (the drift pin in tests/declare_ruby_tool.zig reads both literals).
    // No stdlib in declare chunks: the spec is built with operators only.
    try expectFailure(&.{.{
        .path = "events/wide.lua",
        .source =
        \\local spec = {}
        \\for i = 1, 33 do spec["f" .. i] = 0 end
        \\labelle.event("wide", spec)
        ,
    }}, &.{
        "events/wide.lua:3", // the declaration site
        "event 'wide' has 33 fields",
        "at most 32 fields; split the event",
    });

    // Exactly 32 is the edge — still a legal declaration. Expected JSON
    // is generated to match: fields f00..f31, where zero-padding makes
    // numeric order lexicographic (= sorted).
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(
        testing.allocator,
        "{\"components\":[],\"events\":[{\"name\":\"wide32\",\"fields\":[",
    );
    for (0..32) |i| {
        if (i > 0) try expected.append(testing.allocator, ',');
        const field = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"name\":\"f{d:0>2}\",\"type\":\"i32\",\"default\":0}}",
            .{i},
        );
        defer testing.allocator.free(field);
        try expected.appendSlice(testing.allocator, field);
    }
    try expected.appendSlice(testing.allocator, "]}]}");
    try expectSchema(&.{.{
        .path = "events/wide32.lua",
        .source =
        \\local spec = {}
        \\for i = 0, 31 do spec["f" .. (i < 10 and "0" or "") .. i] = 0 end
        \\labelle.event("wide32", spec)
        ,
    }}, expected.items);
}
