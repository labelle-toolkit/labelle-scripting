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
    // against the shared no-op stub. The declaration BELOW the no-ops
    // still records: the whole body executes.
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
