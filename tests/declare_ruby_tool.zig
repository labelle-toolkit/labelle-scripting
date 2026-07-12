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
            "Labelle.* helpers and non-primitive cross-file constants cannot be used in component specs — declare-mode fields are literals",
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

test "chunk-scope use of a cross-file constant is declare-safe (the ledger seeds the real name)" {
    // THE labelle-engine#772 pattern: events/hunger__feed.rb binds
    // `HungerFeed`, and a script subscribes AT FILE SCOPE with the
    // constant. At runtime one shared VM registers components → events →
    // scripts, so the constant exists before any script chunk loads; this
    // runner gives every chunk a fresh state, so `HungerFeed` cannot
    // resolve by itself — the driver harvests the constants each clean
    // chunk defines WITH their values and re-binds them into every LATER
    // chunk (input order = the assembler's collection order = the runtime
    // registration order, so "earlier" means exactly what it means at
    // runtime). Labelle.event returns the frozen NAME STRING in declare
    // mode too, so `HungerFeed` is a primitive and seeds VERBATIM —
    // the on/emit shims see the real name, exactly like the runtime VM
    // (kwargs and blocks are swallowed, handlers never run). The declare
    // phase must neither run the handler nor fail the build. (A constant
    // NO earlier file defined gets no seed — the typo test below pins the
    // NameError.)
    try expectSchema(&.{
        .{
            .path = "events/hunger__feed.rb",
            .source =
            \\HungerFeed = Labelle.event "hunger__feed", entity: Labelle.id, amount: 0.5
            ,
        },
        .{
            .path = "scripts/feed_watcher.rb",
            .source =
            \\Labelle.on(HungerFeed) do |ev|
            \\  Labelle.log("RUBY_WATCHER_SAW_#{ev[:amount]}")
            \\end
            \\Labelle.emit(HungerFeed, amount: 1.0)
            \\Labelle.emit(HungerFeed)
            \\raise "not the real name" unless HungerFeed == "hunger__feed"
            ,
        },
    },
        \\{"components":[],"events":[{"name":"hunger__feed","fields":[{"name":"amount","type":"f32","default":0.5},{"name":"entity","type":"u64","default":0}]}]}
    );
}

test "a typo'd constant fails at generate naming the file and line (no silent extract)" {
    // The hazard a blanket Module#const_missing had: with EVERY
    // unresolved constant resolving to the sentinel, `Labelle.on(
    // HngerFeed)` — a typo of the declared HungerFeed — extracted
    // silently and only died at RUNTIME as a script eviction. The ledger
    // seeds only constants an EARLIER file really defined, so a typo
    // stays unresolved and NameErrors at extract with the chunk's
    // file:line, exactly like the runtime VM (and like v0.10.0).
    try expectFailure(&.{
        .{
            .path = "events/hunger__feed.rb",
            .source = "HungerFeed = Labelle.event \"hunger__feed\", entity: Labelle.id, amount: 0.5",
        },
        .{ .path = "scripts/feed_watcher.rb", .source = "Labelle.on(HngerFeed) { |ev| }" },
    }, &.{
        "scripts/feed_watcher.rb:1",
        "NameError",
        "uninitialized constant HngerFeed",
    });
    // Spec positions ride the same rule — the typo never resolves far
    // enough to reach the field classifier, so the failure names the
    // CONSTANT (the mistake), not the field.
    try expectFailure(
        &.{.{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Bad\", level: STARTING_LEVEL)" }},
        &.{ "scripts/bad.rb:1", "NameError", "uninitialized constant STARTING_LEVEL" },
    );
}

test "a NON-PRIMITIVE cross-file constant in a spec position is rejected pointedly (sentinel, not a guessed schema)" {
    // The seeded sentinel is legal in CALL positions only (the test
    // above); as a field default it must fail the build naming the field
    // — declare-mode fields are literals or the primitives that mirror
    // them, and a view class is neither. (At runtime the constant holds
    // a Class the schema cannot express; a declaration the extractor
    // cannot see through is a declaration the build must reject, the
    // same posture as Labelle.* helper results.)
    try expectFailure(&.{
        .{ .path = "components/worker.rb", .source = "Worker = Labelle.component \"Worker\", hp: 1" },
        .{ .path = "scripts/bad.rb", .source = "Labelle.component(\"Bad\", level: Worker)" },
    }, &.{
        "scripts/bad.rb:1",
        "component 'Bad' field 'level'",
        "Labelle.* helpers and non-primitive cross-file constants cannot be used in component specs",
    });
    try expectFailure(&.{
        .{ .path = "components/worker.rb", .source = "Worker = Labelle.component \"Worker\", hp: 1" },
        .{ .path = "events/bad.rb", .source = "Labelle.event(\"bad__event\", entity: Worker)" },
    }, &.{
        "events/bad.rb:1",
        "event 'bad__event' field 'entity'",
        "Labelle.* helpers and non-primitive cross-file constants cannot be used in event specs",
    });
}

test "cross-file PRIMITIVE constants classify in spec positions, mirroring the runtime VM" {
    // The tagged ledger's embraced consequence: a primitive an earlier
    // file bound is genuinely visible at runtime (one shared VM), so
    // rejecting `speed: SPEED_DEFAULT` was a FALSE failure — the value
    // seeds verbatim and classifies exactly like the literal it holds
    // (int, string and float here; the event-name string rides the same
    // rule — at runtime HungerFeed IS that string).
    try expectSchema(&.{
        .{
            .path = "scripts/shared.rb",
            .source =
            \\SPEED_DEFAULT = 12.5
            \\LABEL_DEFAULT = "guard"
            \\COIN_DEFAULT = 250
            ,
        },
        .{ .path = "events/hunger__feed.rb", .source = "HungerFeed = Labelle.event \"hunger__feed\", {}" },
        .{
            .path = "scripts/consumer.rb",
            .source =
            \\Labelle.component "Guard", speed: SPEED_DEFAULT, label: LABEL_DEFAULT,
            \\                           coins: COIN_DEFAULT, feed_event: HungerFeed
            ,
        },
    },
        \\{"components":[{"name":"Guard","persist":"persistent","fields":[{"name":"coins","type":"i32","default":250},{"name":"feed_event","type":"str","default":"hunger__feed"},{"name":"label","type":"str","default":"guard"},{"name":"speed","type":"f32","default":12.5}]}],"events":[{"name":"hunger__feed","fields":[]}]}
    );
}

test "a component constant where an event name belongs fails at generate (the on/emit shims)" {
    // The codex finding on #28: `Labelle.on(Worker)` — a real constant of
    // the WRONG KIND (a component, not an event) — used to extract clean
    // (every seeded constant was the call-safe sentinel, and on/emit were
    // blind method_missing no-ops) and only die at RUNTIME:
    // raw_event_subscribe reads the name with mrb_get_args "s", so the
    // Class raised and the script was evicted. The shims validate the
    // name at generate, both across files (Worker arrives as the seeded
    // sentinel)...
    try expectFailure(&.{
        .{ .path = "components/worker.rb", .source = "Worker = Labelle.component \"Worker\", hp: 1" },
        .{ .path = "scripts/bad.rb", .source = "Labelle.on(Worker) { |ev| }" },
    }, &.{
        "scripts/bad.rb:1",
        "Labelle.on: expected an event-name String",
        "non-primitive cross-file constant",
    });
    // ...and in the SAME file, where Worker is the real view class the
    // stub returned — the message can name the component itself.
    try expectFailure(&.{.{
        .path = "scripts/bad.rb",
        .source =
        \\Worker = Labelle.component "Worker", hp: 1
        \\Labelle.on(Worker) { |ev| }
        ,
    }}, &.{
        "scripts/bad.rb:2",
        "Labelle.on: expected an event-name String",
        "the component 'Worker'",
    });
    // Labelle.emit rides the same check, same pair of spellings.
    try expectFailure(&.{
        .{ .path = "components/worker.rb", .source = "Worker = Labelle.component \"Worker\", hp: 1" },
        .{ .path = "scripts/bad.rb", .source = "Labelle.emit(Worker, amount: 1.0)" },
    }, &.{
        "scripts/bad.rb:1",
        "Labelle.emit: expected an event-name String",
        "non-primitive cross-file constant",
    });
    try expectFailure(&.{.{
        .path = "scripts/bad.rb",
        .source =
        \\Worker = Labelle.component "Worker", hp: 1
        \\Labelle.emit(Worker, amount: 1.0)
        ,
    }}, &.{
        "scripts/bad.rb:2",
        "Labelle.emit: expected an event-name String",
        "the component 'Worker'",
    });
}

test "a constant only a LATER file defines fails at generate, matching the runtime load order" {
    // At runtime file-scope code runs when ITS file loads, before later
    // files exist — the reference NameErrors there, so it must NameError
    // here: the ledger seeds strictly forward (input order = collection
    // order = registration order). A blanket const_missing would have
    // extracted this cleanly and shipped the surprise to runtime.
    try expectFailure(&.{
        .{ .path = "scripts/early.rb", .source = "Labelle.on(DefinedLater) { |ev| }" },
        .{ .path = "scripts/late.rb", .source = "DefinedLater = Labelle.event \"defined__later\", {}" },
    }, &.{ "scripts/early.rb:1", "uninitialized constant DefinedLater" });
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
    // view class a.rb bound to `Hunger` must be invisible to b.rb. The
    // constant LEDGER re-binds the NAME into b.rb's fresh state (that is
    // what keeps file-scope `Labelle.on(HungerFeed)` declare-safe) — but
    // as the inert SENTINEL, never the class — so b.rb sees a resolvable
    // name whose use beyond a call position still fails the build with
    // b.rb's file:line, because seeded sentinels answer no methods. Had
    // the class itself leaked, `Hunger.new` would succeed and this
    // expectFailure would fail.
    try expectFailure(&.{
        .{ .path = "scripts/a.rb", .source = "Hunger = Labelle.component(\"Hunger\", hp: 1)" },
        .{ .path = "scripts/b.rb", .source = "Hunger.new" },
    }, &.{ "scripts/b.rb:1", "undefined method 'new'" });
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

test "golden: events emit in their own array — no persist key, declaration order, sorted fields" {
    // labelle-engine#772, the lua golden's ruby twin: the events array
    // trails components, carries NO persist (events are never saved), and
    // follows the same determinism rules — declaration order across
    // files, fields sorted by name. Labelle.id classifies u64 with
    // default 0; the trailing-keywords sugar reads bare like component's.
    // (Every OTHER golden in this file has no events key at all — the
    // emitters may add it only when an event was declared, or those pins
    // break; that absence is the old-assembler compat rule.)
    try expectSchema(&.{
        .{
            .path = "events/hunger__feed.rb",
            .source =
            \\HungerFeed = Labelle.event "hunger__feed", entity: Labelle.id, amount: 0.5
            ,
        },
        .{ .path = "events/wave__spawned.rb", .source = "Labelle.event(\"wave__spawned\", {})" },
    },
        \\{"components":[],"events":[{"name":"hunger__feed","fields":[{"name":"amount","type":"f32","default":0.5},{"name":"entity","type":"u64","default":0}]},{"name":"wave__spawned","fields":[]}]}
    );
}

test "events and components are separate namespaces: one name, both kinds, both emit" {
    // The SAME name declared as a component and as an event is legal —
    // duplicate detection is per kind — and Labelle.id is a legal
    // COMPONENT field too (components gain u64 through the same marker).
    try expectSchema(&.{
        .{
            .path = "scripts/hunger.rb",
            .source =
            \\Labelle.component "Hunger", level: 1.0, owner: Labelle.id
            \\Labelle.event "Hunger", entity: Labelle.id
            ,
        },
    },
        \\{"components":[{"name":"Hunger","persist":"persistent","fields":[{"name":"level","type":"f32","default":1.0},{"name":"owner","type":"u64","default":0}]}],"events":[{"name":"Hunger","fields":[{"name":"entity","type":"u64","default":0}]}]}
    );
}

test "duplicate event declarations fail naming BOTH files" {
    try expectFailure(&.{
        .{ .path = "events/first.rb", .source = "Labelle.event \"hunger__feed\", {}" },
        .{ .path = "events/second.rb", .source = "\nLabelle.event \"hunger__feed\", {}" },
    }, &.{
        "events/second.rb:2", // the redeclaration site (backtrace frame)
        "duplicate event 'hunger__feed'",
        "first declared in events/first.rb",
    });
}

test "malformed event declarations fail with file- and event-bearing errors" {
    // Empty name.
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"\", {})" }},
        &.{ "events/bad.rb:1", "non-empty event name" },
    );
    // Non-identifier name (double underscores ARE legal — hunger__feed
    // passes the goldens above; a space does not).
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"hunger feed\", {})" }},
        &.{ "events/bad.rb:1", "'hunger feed'", "not a valid identifier" },
    );
    // Missing spec hash — payloadless events spell it {} explicitly.
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"tick\")" }},
        &.{ "events/bad.rb:1", "'tick'", "spec Hash" },
    );
    // A third argument is not a persist knob: events take no options —
    // whether it is a literal hash or a no-op sentinel.
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"tick\", {}, { persist: \"transient\" })" }},
        &.{ "events/bad.rb:1", "'tick'", "takes no options (events are not persisted)" },
    );
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"tick\", {}, Labelle.array([]))" }},
        &.{ "events/bad.rb:1", "'tick'", "takes no options (events are not persisted)" },
    );
    // Unsupported field value type.
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"bad\", cb: ->() {})" }},
        &.{ "events/bad.rb:1", "event 'bad' field 'cb'", "unsupported default of type Proc" },
    );
    // The no-op sentinel is rejected in spec and field positions, with
    // the message naming the EVENT DSL.
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"bad\", Labelle.array([]))" }},
        &.{ "events/bad.rb:1", "event 'bad' spec", "cannot be used in event specs — declare-mode fields are literals" },
    );
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"bad\", w: Labelle.array([]))" }},
        &.{ "events/bad.rb:1", "event 'bad' field 'w'", "cannot be used in event specs" },
    );
    // A symbol and a string key normalize to ONE field name — two
    // spellings of the same field fail on the declaration line instead
    // of emitting an ambiguous two-`entity` schema to the assembler.
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"hit\", { entity: Labelle.id, \"entity\" => 0 })" }},
        &.{ "events/bad.rb:1", "event 'hit' field 'entity'", "declared twice" },
    );
    try expectFailure(
        &.{.{ .path = "components/bad.rb", .source = "Labelle.component(\"Hit\", { level: 1.0, \"level\" => 2.0 })" }},
        &.{ "components/bad.rb:1", "component 'Hit' field 'level'", "declared twice" },
    );
}

test "a tampered take seam cannot silently truncate the harvest" {
    // The extractor pulls flat [name, fragment, ...] pairs through the
    // __declare_take* seams; a chunk that shadows one could hand back an
    // odd-length array, and pairing up would silently DROP the trailing
    // item — a successful-looking but incomplete schema. The extractor
    // rejects odd lengths as prelude-integrity breakage: a hard
    // error.DeclarePrelude (the same class as a seam typo), NOT a
    // user-facing .failure outcome.
    try testing.expectError(error.DeclarePrelude, extract.run(testing.allocator, &.{.{
        .path = "events/evil.rb",
        .source = "def Labelle.__declare_take_events; [\"only_a_name\"]; end",
    }}));
}

test "a tampered consts seam cannot slip a non-vocabulary value into the ledger" {
    // The constant ledger's value channel accepts exactly the tag
    // vocabulary — primitives verbatim plus the sentinel Symbol; a
    // shadowed __declare_take_consts handing back anything else (an
    // Array here) or an odd-length flat is the same prelude-integrity
    // class as the truncation test above: hard error.DeclarePrelude,
    // never a lying seed into later chunks.
    try testing.expectError(error.DeclarePrelude, extract.run(testing.allocator, &.{.{
        .path = "scripts/evil.rb",
        .source = "def Labelle.__declare_take_consts; [\"X\", [1, 2]]; end",
    }}));
    try testing.expectError(error.DeclarePrelude, extract.run(testing.allocator, &.{.{
        .path = "scripts/evil.rb",
        .source = "def Labelle.__declare_take_consts; [\"name_without_a_value\"]; end",
    }}));
}

test "Labelle.id is no-arg only, and no spec" {
    // v1 has no id(value) constructor — `Labelle.id(42)` must name the
    // mistake, not classify garbage (ids always default 0).
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.component(\"Bad\", owner: Labelle.id(42))" }},
        &.{ "events/bad.rb:1", "Labelle.id", "takes no arguments" },
    );
    // In spec position the marker is a bare frozen Object, so the
    // existing shape guard names the real problem.
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"bad\", Labelle.id)" }},
        &.{ "events/bad.rb:1", "'bad'", "spec Hash" },
    );
    // Nested inside a vec2-shaped hash: v1 ids are scalar-only.
    try expectFailure(
        &.{.{ .path = "events/bad.rb", .source = "Labelle.event(\"bad\", at: { x: Labelle.id, y: 0 })" }},
        &.{ "events/bad.rb:1", "event 'bad' field 'at'", "unsupported Hash default" },
    );
}

test "the declare-mode event return mimics the runtime value: the frozen name string" {
    // One DSL, two consumers: chunk-scope code holding the result must
    // see the SAME value in both modes (src/ruby/prelude.rb's
    // Labelle.event returns the frozen name). `raise` at chunk scope
    // fails the build, so the fixture is its own assertion.
    try expectSchema(&.{
        .{
            .path = "events/view.rb",
            .source =
            \\HungerFeed = Labelle.event "hunger__feed", entity: Labelle.id
            \\raise "not the name" unless HungerFeed == "hunger__feed"
            \\raise "not frozen" unless HungerFeed.frozen?
            \\raise "id not stable" unless Labelle.id.equal?(Labelle.id)
            \\raise "id not frozen" unless Labelle.id.frozen?
            ,
        },
    },
        \\{"components":[],"events":[{"name":"hunger__feed","fields":[{"name":"entity","type":"u64","default":0}]}]}
    );
}

test "the event field cap fails on the declaration line: 33 rejected, 32 passes" {
    // Event payloads share the view fast path's 32-field ceiling
    // (MAX_VIEW_FIELDS — the drift pin below covers the event twin in the
    // lua runner too): one schema, whatever the language, and the failure
    // names the declaration.
    try expectFailure(&.{.{
        .path = "events/wide.rb",
        .source =
        \\spec = {}
        \\33.times { |i| spec["f%02d" % i] = 0 }
        \\Labelle.event("wide", spec)
        ,
    }}, &.{
        "events/wide.rb:3", // the declaration site
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
        .path = "events/wide32.rb",
        .source =
        \\spec = {}
        \\32.times { |i| spec["f%02d" % i] = 0 }
        \\Labelle.event("wide32", spec)
        ,
    }}, expected.items);
}

test "the view fast path's field cap fails on the declaration line: 33 rejected, 32 passes" {
    // 33 fields: the declaration itself must fail — past declare, the
    // SAME line's runtime half would construct a view whose every
    // get_into/set raises (bindings.zig MAX_REF_FIELDS), and declare-time
    // success + runtime failure is exactly the split-brain the
    // dual-consumer design must not have. The spec is built with core
    // ruby (a Hash is a value however it was made; 33 literal keys would
    // pin nothing extra).
    try expectFailure(&.{.{
        .path = "scripts/wide.rb",
        .source =
        \\spec = {}
        \\33.times { |i| spec["f%02d" % i] = 0 }
        \\Labelle.component("Wide", spec)
        ,
    }}, &.{
        "scripts/wide.rb:3", // the declaration site, not a get/set frame
        "component 'Wide' has 33 fields",
        "at most 32 fields; split the component",
    });

    // Exactly 32 is the edge the raw fast path accepts — still a legal
    // declaration. Expected JSON is generated to match: fields f00..f31,
    // where zero-padding makes numeric order lexicographic (= sorted).
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(
        testing.allocator,
        "{\"components\":[{\"name\":\"Wide32\",\"persist\":\"persistent\",\"fields\":[",
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
        .path = "scripts/wide32.rb",
        .source =
        \\spec = {}
        \\32.times { |i| spec["f%02d" % i] = 0 }
        \\Labelle.component("Wide32", spec)
        ,
    }}, expected.items);
}

/// Parse the integer literal following `needle` in `src` — the field-cap
/// drift pin's source scanner (the packaging pins' technique: read the
/// shipped sources, not a copy of the value).
fn scanCapLiteral(src: []const u8, needle: []const u8) !u32 {
    const at = std.mem.indexOf(u8, src, needle) orelse return error.NeedleNotFound;
    var i = at + needle.len;
    var v: u32 = 0;
    var digits: usize = 0;
    while (i < src.len and std.ascii.isDigit(src[i])) : (i += 1) {
        v = v * 10 + (src[i] - '0');
        digits += 1;
    }
    if (digits == 0) return error.NoDigits;
    return v;
}

test "field-cap drift pin: bindings' MAX_REF_FIELDS equals both preludes' MAX_VIEW_FIELDS" {
    // One number, three languages, no shared source possible: the Zig
    // constant sizes the raw fast path's per-call buffers, the runtime
    // prelude rejects over-wide views at construction, the declare
    // prelude rejects the declaration at build time. If any literal
    // drifts, either declares start passing what runtime rejects (the
    // codex split-brain) or views start rejecting what the raw path
    // accepts — both are this pin. The event DSL rides the same cap
    // (Labelle.event reuses MAX_VIEW_FIELDS; the LUA declare prelude —
    // which never had a component cap to reuse — spells the event
    // ceiling as its own MAX_EVENT_FIELDS literal), so the lua runner's
    // fourth spelling is pinned here too: a drift would let one runner
    // declare an event the other rejects.
    const zig_cap = try scanCapLiteral(
        @embedFile("ruby_bindings_src"),
        "const MAX_REF_FIELDS = ",
    );
    const runtime_cap = try scanCapLiteral(
        @embedFile("ruby_prelude_src"),
        "MAX_VIEW_FIELDS = ",
    );
    const declare_cap = try scanCapLiteral(
        @embedFile("declare_ruby_prelude_src"),
        "MAX_VIEW_FIELDS = ",
    );
    const lua_event_cap = try scanCapLiteral(
        @embedFile("declare_lua_prelude_src"),
        "MAX_EVENT_FIELDS = ",
    );
    try testing.expectEqual(zig_cap, runtime_cap);
    try testing.expectEqual(zig_cap, declare_cap);
    try testing.expectEqual(zig_cap, lua_event_cap);
}
