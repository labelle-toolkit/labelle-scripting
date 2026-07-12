//! labelle-declare-ts goldens — the typescript declare-mode extractor driven
//! in-process (tools/declare-ts/extract.zig via the `declare_ts_core` named
//! module; the quickjs objects come from the typescript-language
//! `labelle_scripting` module already linked into this test binary, so
//! nothing spawns). The typescript member of the cross-runner byte-parity
//! contract (labelle-engine#773, rev 20).
//!
//! Like the lua/ruby runners — and UNLIKE the rust/crystal probes, which are
//! out-of-process compile-and-run tools — the ts runner is an embedded VM, so
//! these goldens RUN a module source string in-process against the declare
//! stub and pin the emitted schema. The cross-runner byte-parity golden lives
//! in tests/declare_cross_golden.zig's shared `expected_json` literal; each
//! language binary pins its own runner against it.

const std = @import("std");
const extract = @import("declare_ts_core");
const cross = @import("declare_cross_golden.zig");

const testing = std.testing;
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

test "cross-runner golden: the ts half — byte-identical to the lua/ruby runners' schema" {
    // The SAME logical declaration set the lua and ruby runners pin
    // (declare_cross_golden.expected_json), spelled as annotation-free ESM and
    // evaluated directly — one logical declaration set, one schema, whatever
    // the language. `number` → f32, `bigint` → i32, labelle.id → u64; float
    // defaults render through the host libc's %.14g exactly as the lua runner's
    // do (1e-05, 3.4e+38, forced "1.0"); the mixed vec2 keeps each axis's type.
    try expectSchema(
        &.{.{ .path = cross.ts_path, .source = cross.ts_source }},
        cross.expected_json,
    );
}

test "golden: every v1-inferable type, declaration order + sorted fields, across two modules" {
    // Module isolation is the language's own (no shared top-level bindings),
    // so two files never collide and no constant ledger is needed. Components
    // emit in DECLARATION order (argv order, then top-to-bottom); fields emit
    // SORTED. `number` → f32 (floatness forced), `bigint` → i32, bool → bool,
    // string → str, { x, y } → vec2 (each axis by its own type).
    try expectSchema(&.{
        .{
            .path = "components/hunger.js",
            .source =
            \\export const Hunger = labelle.component("Hunger", { level: 1.0, starving: false });
            \\export const Wallet = labelle.component("Wallet", { coins: 250n });
            ,
        },
        .{
            .path = "components/patrol.js",
            .source =
            \\export const Patrol = labelle.component("Patrol", {
            \\  speed: 12.5,
            \\  home: { x: 4.0, y: -2n },
            \\  label: "guard \"one\"",
            \\  active: true,
            \\}, { persist: "transient" });
            ,
        },
    },
        \\{"components":[{"name":"Hunger","persist":"persistent","fields":[{"name":"level","type":"f32","default":1.0},{"name":"starving","type":"bool","default":false}]},{"name":"Wallet","persist":"persistent","fields":[{"name":"coins","type":"i32","default":250}]},{"name":"Patrol","persist":"transient","fields":[{"name":"active","type":"bool","default":true},{"name":"home","type":"vec2","default":{"x":4.0,"y":-2}},{"name":"label","type":"str","default":"guard \"one\""},{"name":"speed","type":"f32","default":12.5}]}]}
    );
}

test "golden: a field-less marker component and a declaration-free module" {
    // {} declares a zero-field marker; a module with no declarations
    // contributes nothing; NO declarations at all → the empty schema (the
    // assembler's no-op gate keys on exactly this).
    try expectSchema(&.{
        .{ .path = "components/dead.js", .source = "labelle.component(\"Dead\", {}, { persist: \"transient\" });" },
        .{ .path = "scripts/b.js", .source = "export function update(dt) {}" },
    },
        \\{"components":[{"name":"Dead","persist":"transient","fields":[]}]}
    );
    try expectSchema(&.{.{ .path = "scripts/b.js", .source = "export function update(dt) {}" }},
        \\{"components":[]}
    );
}

test "golden: events emit in their own array — no persist key, declaration order, sorted fields" {
    // labelle-engine#772's ts twin: the events array trails components, carries
    // NO persist, and follows the same determinism rules. labelle.id classifies
    // u64 with default 0. (Every OTHER golden here has no events key at all —
    // the emitter adds it only when an event was declared, the old-assembler
    // compat rule.)
    try expectSchema(&.{
        .{
            .path = "events/hunger__feed.js",
            .source = "export const HungerFeed = labelle.event(\"hunger__feed\", { entity: labelle.id, amount: 0.5 });",
        },
        .{ .path = "events/wave__spawned.js", .source = "labelle.event(\"wave__spawned\", {});" },
    },
        \\{"components":[],"events":[{"name":"hunger__feed","fields":[{"name":"amount","type":"f32","default":0.5},{"name":"entity","type":"u64","default":0}]},{"name":"wave__spawned","fields":[]}]}
    );
}

test "events and components are separate namespaces: one name, both kinds, both emit" {
    // The SAME name declared as a component and an event is legal — duplicate
    // detection is per kind — and labelle.id is a legal COMPONENT field too.
    try expectSchema(&.{
        .{
            .path = "components/hunger.js",
            .source =
            \\labelle.component("Hunger", { level: 1.0, owner: labelle.id });
            \\labelle.event("Hunger", { entity: labelle.id });
            ,
        },
    },
        \\{"components":[{"name":"Hunger","persist":"persistent","fields":[{"name":"level","type":"f32","default":1.0},{"name":"owner","type":"u64","default":0}]}],"events":[{"name":"Hunger","fields":[{"name":"entity","type":"u64","default":0}]}]}
    );
}

test "the declare-mode returns mimic the runtime values: a ref and the name string" {
    // One DSL, two consumers: module-scope code holding the result sees the
    // SAME shape in both modes (src/ts/prelude.js — component returns
    // { __labelle_component }, event returns the name string). A thrown error
    // fails the module, so the fixture is its own assertion.
    try expectSchema(&.{
        .{
            .path = "components/view.js",
            .source =
            \\const Hunger = labelle.component("Hunger", { level: 1.0 });
            \\if (Hunger.__labelle_component !== "Hunger") throw new Error("ref shape wrong");
            \\const Feed = labelle.event("hunger__feed", { amount: 0.5 });
            \\if (Feed !== "hunger__feed") throw new Error("event return wrong");
            ,
        },
    },
        \\{"components":[{"name":"Hunger","persist":"persistent","fields":[{"name":"level","type":"f32","default":1.0}]}],"events":[{"name":"hunger__feed","fields":[{"name":"amount","type":"f32","default":0.5}]}]}
    );
}

test "duplicate declarations fail naming BOTH files; malformed specs name the field" {
    try expectFailure(&.{
        .{ .path = "components/first.js", .source = "labelle.component(\"Hunger\", { level: 1.0 });" },
        .{ .path = "components/second.js", .source = "\nlabelle.component(\"Hunger\", { level: 2.0 });" },
    }, &.{ "duplicate component 'Hunger'", "first declared in components/first.js" });

    // A function default has no schema type.
    try expectFailure(
        &.{.{ .path = "components/bad.js", .source = "labelle.component(\"Bad\", { cb: () => {} });" }},
        &.{ "component 'Bad' field 'cb'", "unsupported default" },
    );
    // A bigint outside i32.
    try expectFailure(
        &.{.{ .path = "components/bad.js", .source = "labelle.component(\"Big\", { n: 3000000000n });" }},
        &.{ "component 'Big' field 'n'", "out of i32 range" },
    );
    // A finite-but-huge number no f32 can hold.
    try expectFailure(
        &.{.{ .path = "components/bad.js", .source = "labelle.component(\"Big\", { v: 1e100 });" }},
        &.{ "component 'Big' field 'v'", "out of f32 range" },
    );
    // A non-vec2 object shape.
    try expectFailure(
        &.{.{ .path = "components/bad.js", .source = "labelle.component(\"Bad\", { p: { a: 1, b: 2 } });" }},
        &.{ "component 'Bad' field 'p'", "unsupported object default" },
    );
    // An event with a 3rd argument (events take no options).
    try expectFailure(
        &.{.{ .path = "events/bad.js", .source = "labelle.event(\"tick\", {}, { persist: \"transient\" });" }},
        &.{ "event 'tick'", "takes no options" },
    );
}

test "drift pin: the ts golden fixture is game-shaped — no import statement" {
    // The fixture the golden evaluates must be game-shaped: NO `import`
    // statement (the tool provides `labelle` as a global; a real declaration
    // file omits imports, and the transpiled ESM the assembler feeds the tool
    // has none either). Line-based via startsWith, NOT a substring indexOf: a
    // header COMMENT mentioning "import" (or the word inside a string literal)
    // must not trip this — only a real statement line does. The per-line trim
    // also drops any `\r`, so the check is line-ending-agnostic. (This is the
    // rust drift-pin's game-shaped check, using startsWith from the start to
    // avoid the substring-vs-comment hazard that pattern hit.)
    var lines = std.mem.splitScalar(u8, cross.ts_source, '\n');
    while (lines.next()) |line| {
        const stripped = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, stripped, "import ") or
            std.mem.startsWith(u8, stripped, "import{") or
            std.mem.startsWith(u8, stripped, "import(") or
            std.mem.eql(u8, stripped, "import"))
        {
            std.debug.print(
                "the ts golden fixture hand-added an `import` — that hides the tool's global `labelle` injection\n",
                .{},
            );
            return error.TsFixtureNotGameShaped;
        }
    }
}
