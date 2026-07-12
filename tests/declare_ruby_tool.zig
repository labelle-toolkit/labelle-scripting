//! labelle-declare-ruby goldens — the ruby declare-mode extractor driven
//! in-process (tools/declare-ruby/extract.zig via the `declare_ruby_core`
//! named module; the mruby objects come from the ruby-language
//! `labelle_scripting` module already linked into this test binary, so
//! nothing spawns).
//!
//! Test-for-test mirror of tests/declare_tool.zig (the lua goldens) in
//! ruby spelling: the exact schema JSON for a representative declaration
//! set, the declaration-order / sorted-fields determinism rules, the
//! "only the chunk body runs, only `Labelle` is in scope" execution
//! model, the file-and-name-bearing failure text for every
//! malformed-spec class — plus the ruby-specific pins (fresh-interpreter
//! isolation, controller-subclass chunk bodies, the view-class return
//! mimic) and the cross-runner byte-parity golden shared with the lua
//! file through tests/declare_cross_golden.zig.

const std = @import("std");
const extract = @import("declare_ruby_core");
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
    // The lua matrix in ruby types: Float→f32, Integer→i32, bool→bool,
    // String→str, { x:, y: }→vec2. Components emit in DECLARATION order
    // (argv order, then top-to-bottom); fields emit SORTED (one contract,
    // whatever the language — lua cannot recover field order). Float
    // defaults always carry their floatness ("1.0", "4.0"); the vec2's y
    // stays the integer it was declared as. The first file uses the
    // trailing-keywords sugar (`level: 1.0` with no braces — ruby
    // collapses them into the spec hash); the second the braced-spec +
    // opts spelling.
    try expectSchema(&.{
        .{
            .path = "scripts/hunger.rb",
            .source =
            \\Labelle.component "Hunger", level: 1.0, starving: false
            \\Labelle.component "Wallet", coins: 250
            ,
        },
        .{
            .path = "scripts/ai/guard.rb",
            // `Patrol = ...`: the declare stub returns the same view-class
            // shape the runtime does, so ref-binding chunk scope is legal
            // in both modes.
            .source =
            \\Patrol = Labelle.component("Patrol", {
            \\  speed: 12.5,
            \\  home: { x: 4.0, y: -2 },
            \\  label: "guard \"one\"",
            \\  active: true,
            \\}, { persist: "transient" })
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
        .{ .path = "scripts/a.rb", .source = "Labelle.component(\"Dead\", {}, { persist: \"transient\" })" },
        .{ .path = "scripts/b.rb", .source = "def update(dt); end" },
    },
        \\{"components":[{"name":"Dead","persist":"transient","fields":[]}]}
    );
    try expectSchema(&.{.{ .path = "scripts/b.rb", .source = "def update(dt); end" }},
        \\{"components":[]}
    );
}

test "only the chunk body runs: hooks and controllers never fire, other Labelle.* are silent no-ops" {
    // init/setup/tick would blow up at runtime — declare mode never calls
    // them. Chunk-scope Labelle.on/log/array run against the
    // sentinel-returning no-op (results discarded here), and the runtime
    // API's classes no-op the same way: `Labelle::Component.ref` binds its
    // sentinel, `class ... < Labelle::Controller` subclasses the bare stub
    // (a NameError there would make declare unusable — controller
    // definitions ARE chunk scope in ruby). The declaration BELOW it all
    // still records: the whole body executes.
    try expectSchema(&.{
        .{
            .path = "scripts/spiky.rb",
            .source =
            \\Labelle.on("ping") { |ev| }
            \\Labelle.log("chunk scope")
            \\Labelle.array([])
            \\Cached = Labelle::Component.ref("Cached", :n)
            \\class SpikyController < Labelle::Controller
            \\  def setup
            \\    raise "setup must never run in declare mode"
            \\  end
            \\
            \\  def tick(dt)
            \\    raise "nor tick"
            \\  end
            \\end
            \\def init
            \\  raise "init must never run in declare mode"
            \\  Labelle::Entity.create.set("X", Labelle.query("Y"))
            \\end
            \\def update(dt)
            \\  raise "nor update"
            \\end
            \\Labelle.component("Spiky", n: 1)
            ,
        },
    },
        \\{"components":[{"name":"Spiky","persist":"persistent","fields":[{"name":"n","type":"i32","default":1}]}]}
    );
}

test "duplicate declarations fail naming BOTH files" {
    try expectFailure(&.{
        .{ .path = "scripts/first.rb", .source = "Labelle.component \"Hunger\", level: 1.0" },
        .{ .path = "scripts/second.rb", .source = "\nLabelle.component \"Hunger\", level: 2.0" },
    }, &.{
        "scripts/second.rb:2", // the redeclaration site (backtrace frame)
        "duplicate component 'Hunger'",
        "first declared in scripts/first.rb",
    });
}

test "malformed specs fail with file-, component- and field-bearing errors" {
    // Empty name.
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"\", {})" }},
        &.{ "scripts/bad.rb:1", "non-empty component name" },
    );
    // Non-identifier name.
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Hun ger\", {})" }},
        &.{ "scripts/bad.rb:1", "'Hun ger'", "not a valid identifier" },
    );
    // Missing spec hash.
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Hunger\")" }},
        &.{ "scripts/bad.rb:1", "'Hunger'", "spec Hash" },
    );
    // Unsupported field value type (procs have no schema type).
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Bad\", cb: ->() {})" }},
        &.{ "scripts/bad.rb:1", "component 'Bad' field 'cb'", "unsupported default of type Proc" },
    );
    // A non-vec2 collection default — ruby splits lua's "table" into two
    // classes, both rejected: an Array is no schema type at all...
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Bad\", path: [1, 2, 3])" }},
        &.{ "scripts/bad.rb:1", "component 'Bad' field 'path'", "unsupported default of type Array" },
    );
    // ...and a Hash that isn't the { x:, y: } vec2 shape.
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Bad\", path: { a: 1, b: 2, c: 3 })" }},
        &.{ "scripts/bad.rb:1", "component 'Bad' field 'path'", "unsupported Hash default" },
    );
    // Integer default outside i32 (u32/entity are schema-only in v1 — no
    // ruby spelling reaches them).
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Big\", n: 3000000000)" }},
        &.{ "scripts/bad.rb:1", "component 'Big' field 'n'", "out of i32 range" },
    );
    // Bad persist value / unknown option key.
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Hunger\", {}, { persist: \"forever\" })" }},
        &.{ "scripts/bad.rb:1", "'Hunger'", "invalid persist value 'forever'" },
    );
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Hunger\", {}, { presist: \"transient\" })" }},
        &.{ "scripts/bad.rb:1", "'Hunger'", "unknown option 'presist'" },
    );
}

test "Labelle.* helper results in a spec fail the build instead of silently misdeclaring" {
    // `waypoints: Labelle.array([])`: were the no-op to return nil, the
    // hash would carry a nil default and misreport as "unsupported default
    // of type NilClass" — naming the symptom, not the mistake. The no-ops
    // return a sentinel that `component` rejects with a pointed message.
    try expectFailure(
        &.{.{
            .path = "scripts/path.rb",
            .source = "Labelle.component(\"Path\", waypoints: Labelle.array([]))",
        }},
        &.{
            "scripts/path.rb:1",
            "component 'Path' field 'waypoints'",
            "Labelle.* helpers cannot be used in component specs — declare-mode fields are literals",
        },
    );
    // The spec and opts positions are scanned too — a nil-returning no-op
    // in the OPTS slot would silently declare the component without its
    // intended options (nil opts == no opts), the ruby twin of lua's
    // dropped-key hazard.
    try expectFailure(
        &.{.{ .path = "scripts/path.rb", .source = "Labelle.component(\"Path\", Labelle.array([]))" }},
        &.{ "scripts/path.rb:1", "component 'Path' spec", "declare-mode fields are literals" },
    );
    try expectFailure(
        &.{.{ .path = "scripts/path.rb", .source = "Labelle.component(\"Path\", {}, Labelle.array([]))" }},
        &.{ "scripts/path.rb:1", "component 'Path' options", "declare-mode fields are literals" },
    );
}

test "float defaults must fit f32: finite-but-huge fails alongside NaN/inf; the edge passes" {
    // 1e100 / -1e100 are FINITE doubles no f32 can hold — accepting them
    // would emit impossible "f32" defaults for the assembler to codegen.
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Big\", v: 1e100)" }},
        &.{ "scripts/bad.rb:1", "component 'Big' field 'v'", "out of f32 range" },
    );
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Big\", v: -1e100)" }},
        &.{ "scripts/bad.rb:1", "component 'Big' field 'v'", "out of f32 range" },
    );
    // Non-finite values keep their own error class (float division —
    // integer 0/0 would raise ZeroDivisionError instead, ruby's own rule).
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Bad\", v: 0.0 / 0)" }},
        &.{ "scripts/bad.rb:1", "component 'Bad' field 'v'", "non-finite" },
    );
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Bad\", v: 1.0 / 0)" }},
        &.{ "scripts/bad.rb:1", "component 'Bad' field 'v'", "non-finite" },
    );
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Bad\", v: -1.0 / 0)" }},
        &.{ "scripts/bad.rb:1", "component 'Bad' field 'v'", "non-finite" },
    );
    // 3.4e38 sits just under f32 max (3.4028235e38): still a legal
    // default, and %.14g keeps it exact.
    try expectSchema(&.{.{ .path = "scripts/edge.rb", .source = "Labelle.component(\"Edge\", v: 3.4e38)" }},
        \\{"components":[{"name":"Edge","persist":"persistent","fields":[{"name":"v","type":"f32","default":3.4e+38}]}]}
    );
    // vec2 axes ride the same range check (a mixed float/integer pair is
    // still a vec2).
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Bad\", home: { x: 1e100, y: 0 })" }},
        &.{ "scripts/bad.rb:1", "component 'Bad' field 'home'", "out of f32 range" },
    );
}

test "a chunk clobbering Labelle cannot poison later chunks (fresh interpreter per chunk)" {
    // clobber.rb REOPENS the Labelle module and redefines `component` to a
    // nil-returning stub — the most hostile spelling ruby offers (there is
    // no per-chunk _ENV to hide behind; a shared interpreter would hand
    // every later file the broken recorder and their declarations would
    // vanish silently). Each chunk gets a fresh mrb_state, so the
    // mutation dies with clobber.rb's interpreter.
    try expectSchema(&.{
        .{
            .path = "scripts/clobber.rb",
            .source =
            \\module Labelle
            \\  def self.component(*_args)
            \\    nil
            \\  end
            \\end
            ,
        },
        .{ .path = "scripts/after.rb", .source = "Labelle.component(\"Survivor\", hp: 3)" },
    },
        \\{"components":[{"name":"Survivor","persist":"persistent","fields":[{"name":"hp","type":"i32","default":3}]}]}
    );
}

test "chunk-scope code outside the Labelle stub fails loudly with its location" {
    // Declare mode's callable surface is the stub `Labelle` (plus ruby's
    // own core — hashes, strings and `raise` ARE the language). The
    // runtime contract's sugar lives nowhere else: `puts` does not exist
    // in the game VM either (no mruby-print gem), and calling it at chunk
    // scope must fail the build with the file:line, not silently skip the
    // script.
    try expectFailure(
        &.{.{ .path = "scripts/chatty.rb", .source = "puts \"hello\"" }},
        &.{ "scripts/chatty.rb:1", "puts" },
    );
    // Compile errors carry their location the same way (the "line N:"
    // SyntaxError prefix is grafted onto the path).
    try expectFailure(
        &.{.{ .path = "scripts/broken.rb", .source = "def oops(" }},
        &.{ "scripts/broken.rb:1", "syntax error" },
    );
}

test "chunks are isolated: one script's top-level defs and constants never leak into the next" {
    // a.rb defines `helper` at top level (landing on ITS interpreter's
    // Object) — b.rb calling it must fail, same isolation the runtime VM's
    // harvest protocol gives registered scripts.
    try expectFailure(&.{
        .{ .path = "scripts/a.rb", .source = "def helper\nend\nLabelle.component(\"A\", {})" },
        .{ .path = "scripts/b.rb", .source = "helper()" },
    }, &.{ "scripts/b.rb:1", "helper" });
    // Constants too — ruby's extra leak surface lua locals never had: the
    // view class a.rb bound to `Hunger` must be invisible to b.rb.
    try expectFailure(&.{
        .{ .path = "scripts/a.rb", .source = "Hunger = Labelle.component(\"Hunger\", hp: 1)" },
        .{ .path = "scripts/b.rb", .source = "Hunger.new" },
    }, &.{ "scripts/b.rb:1", "Hunger" });
}

test "the declare-mode return value mimics the runtime view class" {
    // One DSL, two consumers: chunk-scope code holding the result must see
    // the SAME shape in both modes (src/ruby/prelude.rb's Component.__view
    // — Struct-backed, component_name/component_fields, field order = spec
    // insertion order). `raise` at chunk scope fails the build, so the
    // fixture is its own assertion.
    try expectSchema(&.{
        .{
            .path = "scripts/view.rb",
            .source =
            \\Hunger = Labelle.component "Hunger", level: 1.0, starving: false
            \\raise "not a class" unless Hunger.is_a?(Class)
            \\raise "wrong name" unless Hunger.component_name == "Hunger"
            \\raise "wrong fields" unless Hunger.component_fields == [:level, :starving]
            \\h = Hunger.new
            \\h.level = 2.0
            \\raise "accessor broken" unless h.level == 2.0
            \\raise "instance name broken" unless h.component_name == "Hunger"
            \\Dead = Labelle.component("Dead", {})
            \\raise "marker not a class" unless Dead.is_a?(Class)
            \\raise "marker fields" unless Dead.component_fields == []
            \\Labelle.component("Ok", done: true)
            ,
        },
    },
        \\{"components":[{"name":"Hunger","persist":"persistent","fields":[{"name":"level","type":"f32","default":1.0},{"name":"starving","type":"bool","default":false}]},{"name":"Dead","persist":"persistent","fields":[]},{"name":"Ok","persist":"persistent","fields":[{"name":"done","type":"bool","default":true}]}]}
    );
}

test "cross-runner golden: the ruby half — byte-identical to the lua runner's schema" {
    // The other half lives in tests/declare_tool.zig (the lua binary);
    // both assert the SAME expected literal from declare_cross_golden.zig.
    try expectSchema(
        &.{.{ .path = cross.ruby_path, .source = cross.ruby_source }},
        cross.expected_json,
    );
}
