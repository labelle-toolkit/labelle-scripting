//! The cross-runner declare golden: ONE logical declaration set, spelled
//! in lua and in ruby, and the ONE schema JSON both runners must emit for
//! it — byte-identical. The lua half is asserted in tests/declare_tool.zig
//! (the lua test binary), the ruby half in tests/declare_ruby_tool.zig
//! (the ruby test binary); sharing the expected literal through this
//! module is what makes the two pins the same pin. This is the
//! runner↔runner half of the runner↔assembler contract: parseSchema never
//! learns which language produced the JSON, so the runners must not
//! diverge on a byte.
//!
//! The fixture deliberately stacks every formatting edge the emitters
//! could disagree on: float floatness-forcing ("1.0"), %.14g exponent
//! rendering (1e-05, 3.4e+38 — lua formats through the host libc, ruby
//! through mruby's vendored fmt_fp), i32 extremes, a mixed float/integer
//! vec2, string escapes (quote, newline, tab, backslash), field sorting,
//! a transient zero-field marker, and declaration order — plus the events
//! surface (labelle-engine#772): component and event declarations
//! INTERLEAVED in one file (each kind keeps its own declaration order in
//! its own array), a multi-field event covering the id marker alongside
//! f32/bool/str/vec2, a payloadless `{}` event, and the id marker in a
//! COMPONENT field (components gain u64 the same way).

/// What both spellings declare (paths only matter for error attribution —
/// the schema carries no file info; these use the scripts/ convention-dir
/// shape real games have).
pub const lua_path = "scripts/kinematics.lua";
pub const lua_source =
    \\local Kinematics = labelle.component("Kinematics", {
    \\  speed = 12.5,
    \\  accel = 1.0,
    \\  tiny = 1e-05,
    \\  huge = 3.4e38,
    \\  jump_count = 3,
    \\  min_i32 = -2147483648,
    \\  max_i32 = 2147483647,
    \\  grounded = true,
    \\  home = { x = -0.5, y = 7 },
    \\  label = "he said \"hi\"\n\ttab\\done",
    \\  owner = labelle.id,
    \\})
    \\local HungerFeed = labelle.event("hunger__feed", {
    \\  entity = labelle.id,
    \\  amount = 0.5,
    \\  urgent = false,
    \\  reason = "why \"now\"",
    \\  at = { x = -1.5, y = 3 },
    \\})
    \\labelle.component("Dead", {}, { persist = "transient" })
    \\labelle.event("wave__spawned", {})
;

pub const ruby_path = "scripts/kinematics.rb";
pub const ruby_source =
    \\Kinematics = Labelle.component("Kinematics", {
    \\  speed: 12.5,
    \\  accel: 1.0,
    \\  tiny: 1e-05,
    \\  huge: 3.4e38,
    \\  jump_count: 3,
    \\  min_i32: -2147483648,
    \\  max_i32: 2147483647,
    \\  grounded: true,
    \\  home: { x: -0.5, y: 7 },
    \\  label: "he said \"hi\"\n\ttab\\done",
    \\  owner: Labelle.id,
    \\})
    \\HungerFeed = Labelle.event("hunger__feed", {
    \\  entity: Labelle.id,
    \\  amount: 0.5,
    \\  urgent: false,
    \\  reason: "why \"now\"",
    \\  at: { x: -1.5, y: 3 },
    \\})
    \\Labelle.component("Dead", {}, { persist: "transient" })
    \\Labelle.event("wave__spawned", {})
;

pub const expected_json =
    \\{"components":[{"name":"Kinematics","persist":"persistent","fields":[{"name":"accel","type":"f32","default":1.0},{"name":"grounded","type":"bool","default":true},{"name":"home","type":"vec2","default":{"x":-0.5,"y":7}},{"name":"huge","type":"f32","default":3.4e+38},{"name":"jump_count","type":"i32","default":3},{"name":"label","type":"str","default":"he said \"hi\"\n\ttab\\done"},{"name":"max_i32","type":"i32","default":2147483647},{"name":"min_i32","type":"i32","default":-2147483648},{"name":"owner","type":"u64","default":0},{"name":"speed","type":"f32","default":12.5},{"name":"tiny","type":"f32","default":1e-05}]},{"name":"Dead","persist":"transient","fields":[]}],"events":[{"name":"hunger__feed","fields":[{"name":"amount","type":"f32","default":0.5},{"name":"at","type":"vec2","default":{"x":-1.5,"y":3}},{"name":"entity","type":"u64","default":0},{"name":"reason","type":"str","default":"why \"now\""},{"name":"urgent","type":"bool","default":false}]},{"name":"wave__spawned","fields":[]}]}
;
