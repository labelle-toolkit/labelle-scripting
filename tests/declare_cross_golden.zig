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

// The rust spelling (labelle-engine#774, rev 17). Unlike lua/ruby —
// interpreted, so their runner RUNS one source string in-process — rust has no
// interpreter: the declare tool (labelle-declare-rs) is a probe that
// cargo-BUILDS the declaration files it is handed. The assembler hands it
// components/*.rs then events/*.rs (argv order = registration order), so the
// canonical spelling splits into a GAME-SHAPED component file and event file —
// bare `labelle::component!{…}` / `vec2(…)` with NO `use` lines (a real game
// omits them; the tool injects `use crate::labelle; use crate::labelle::vec2;`).
// Types are EXPLICIT (rust is typed): the schema's f32/bool/i32/u64/vec2/str
// vocabulary is spelled directly, `u64` standing where lua/ruby wrote the
// `labelle.id` marker (ids default 0). tests/declare_rust_tool.zig runs the
// tool over the tools/declare-rs/testdata fixtures, pins its stdout against
// `expected_json`, and drift-pins each fixture against the block below.
pub const rust_components_source =
    \\labelle::component! {
    \\    Kinematics {
    \\        speed: f32 = 12.5,
    \\        accel: f32 = 1.0,
    \\        tiny: f32 = 1e-05,
    \\        huge: f32 = 3.4e38,
    \\        jump_count: i32 = 3,
    \\        min_i32: i32 = -2147483648,
    \\        max_i32: i32 = 2147483647,
    \\        grounded: bool = true,
    \\        home: vec2 = vec2(-0.5, 7.0),
    \\        label: str = "he said \"hi\"\n\ttab\\done",
    \\        owner: u64 = 0,
    \\    }
    \\}
    \\
    \\labelle::component! {
    \\    transient Dead {}
    \\}
;

pub const rust_events_source =
    \\labelle::event! {
    \\    hunger__feed {
    \\        entity: u64 = 0,
    \\        amount: f32 = 0.5,
    \\        urgent: bool = false,
    \\        reason: str = "why \"now\"",
    \\        at: vec2 = vec2(-1.5, 3.0),
    \\    }
    \\}
    \\
    \\labelle::event! {
    \\    wave__spawned {}
    \\}
;

// The crystal spelling (labelle-engine#775) — rust's native-family TWIN.
// Crystal has no interpreter either, so its declare tool (labelle-declare-
// crystal) is the same "compile-and-run probe" as rust's: it `crystal build`s
// the declaration files it is handed. The assembler hands it components/*.cr
// then events/*.cr (argv order = registration order), so the canonical
// spelling splits into a GAME-SHAPED component file and event file — bare
// `Labelle.component "…"` / `Labelle.event "…"` with NO `require` lines (a real
// game omits them; the tool injects `require "./labelle"`). Each field is a
// `{type, default}` tuple whose type keyword (f32/bool/i32/u64/vec2/str) is
// read only as macro AST, never evaluated — `u64` standing where lua/ruby wrote
// the `labelle.id` marker (ids default 0). tests/declare_crystal_tool.zig runs
// the tool over the tools/declare-crystal/testdata fixtures, pins its stdout
// against `expected_json`, and drift-pins each fixture against the block below.
pub const crystal_components_source =
    \\Labelle.component "Kinematics", {
    \\  speed:      {f32, 12.5},
    \\  accel:      {f32, 1.0},
    \\  tiny:       {f32, 1e-05},
    \\  huge:       {f32, 3.4e38},
    \\  jump_count: {i32, 3},
    \\  min_i32:    {i32, -2147483648},
    \\  max_i32:    {i32, 2147483647},
    \\  grounded:   {bool, true},
    \\  home:       {vec2, {-0.5, 7.0}},
    \\  label:      {str, "he said \"hi\"\n\ttab\\done"},
    \\  owner:      {u64, 0},
    \\}
    \\
    \\Labelle.component "Dead", persist: "transient"
;

pub const crystal_events_source =
    \\Labelle.event "hunger__feed", {
    \\  entity: {u64, 0},
    \\  amount: {f32, 0.5},
    \\  urgent: {bool, false},
    \\  reason: {str, "why \"now\""},
    \\  at:     {vec2, {-1.5, 3.0}},
    \\}
    \\
    \\Labelle.event "wave__spawned"
;

// The typescript spelling (labelle-engine#773, rev 20). Like lua/ruby it runs
// in-process — quickjs is embedded, so tests/declare_ts_tool.zig evals these
// module sources DIRECTLY through the `declare_ts_core` extractor (no tsc in
// scripting CI: the source is self-contained, annotation-free ESM). Under the
// assembler's rev-20 option (b) the tool receives the EMITTED `.js`, but the
// declaration DSL is plain runnable JS either way, so the golden evaluates the
// authored ESM as-is. JS has ONE Number type, so the int/float split the
// schema needs is spelled by JS types: a `number` literal (12.5, 1.0, 1e-05)
// → f32, a `bigint` literal (3n, 7n) → i32, `labelle.id` → u64 — mirroring
// lua/ruby's float/int inference and this codebase's "ids are BigInt"
// convention. Game-shaped: NO `import` lines (the tool provides `labelle` as a
// global; tests/declare_ts_tool.zig's drift pin proves the absence).
pub const ts_path = "scripts/kinematics.ts";
pub const ts_source =
    \\export const Kinematics = labelle.component("Kinematics", {
    \\  speed: 12.5,
    \\  accel: 1.0,
    \\  tiny: 1e-05,
    \\  huge: 3.4e38,
    \\  jump_count: 3n,
    \\  min_i32: -2147483648n,
    \\  max_i32: 2147483647n,
    \\  grounded: true,
    \\  home: { x: -0.5, y: 7n },
    \\  label: "he said \"hi\"\n\ttab\\done",
    \\  owner: labelle.id,
    \\});
    \\export const HungerFeed = labelle.event("hunger__feed", {
    \\  entity: labelle.id,
    \\  amount: 0.5,
    \\  urgent: false,
    \\  reason: "why \"now\"",
    \\  at: { x: -1.5, y: 3n },
    \\});
    \\labelle.component("Dead", {}, { persist: "transient" });
    \\labelle.event("wave__spawned", {});
;

// The C# spelling (labelle-scripting#27, labelle-engine#743) — rust's / crystal's
// CoreCLR-family TWIN. C# is compiled, so its declare tool (labelle-declare-
// csharp) is the same "compile-and-run probe": it `dotnet build`s the declaration
// files it is handed. The assembler hands it components/*.cs then events/*.cs
// (argv order = registration order), so the canonical spelling splits into a
// GAME-SHAPED component file and event file — attributed `record`s with public-
// field defaults and NO `using` lines (the declare surface `[LabelleComponent]`
// / `[LabelleEvent]` / `Vec2` is GLOBAL; a real game omits imports, the tool
// injects nothing). A float default is spelled `double` so its as-written decimal
// formats at full f64 precision (schema type is still f32 — matching rust's
// bind-to-f64 rule); `int`→i32, `bool`, `string`→str, `Vec2`→vec2, and `ulong`
// stands where lua/ruby wrote the `labelle.id` marker (ids default 0). The record
// TYPE NAME is the component/event name (a lowercase `record hunger__feed` is
// legal — these records are DECLARE-ONLY, never a runtime type).
// tests/declare_csharp_tool.zig runs the tool over the tools/declare-csharp/
// testdata fixtures, pins its stdout against `expected_json`, and drift-pins each
// fixture against the block below.
pub const csharp_components_source =
    \\[LabelleComponent]
    \\record Kinematics
    \\{
    \\    public double speed = 12.5;
    \\    public double accel = 1.0;
    \\    public double tiny = 1e-05;
    \\    public double huge = 3.4e38;
    \\    public int jump_count = 3;
    \\    public int min_i32 = -2147483648;
    \\    public int max_i32 = 2147483647;
    \\    public bool grounded = true;
    \\    public Vec2 home = new(-0.5, 7.0);
    \\    public string label = "he said \"hi\"\n\ttab\\done";
    \\    public ulong owner = 0;
    \\}
    \\
    \\[LabelleComponent(Persist.Transient)]
    \\record Dead;
;

pub const csharp_events_source =
    \\[LabelleEvent]
    \\record hunger__feed
    \\{
    \\    public ulong entity = 0;
    \\    public double amount = 0.5;
    \\    public bool urgent = false;
    \\    public string reason = "why \"now\"";
    \\    public Vec2 at = new(-1.5, 3.0);
    \\}
    \\
    \\[LabelleEvent]
    \\record wave__spawned;
;

pub const expected_json =
    \\{"components":[{"name":"Kinematics","persist":"persistent","fields":[{"name":"accel","type":"f32","default":1.0},{"name":"grounded","type":"bool","default":true},{"name":"home","type":"vec2","default":{"x":-0.5,"y":7}},{"name":"huge","type":"f32","default":3.4e+38},{"name":"jump_count","type":"i32","default":3},{"name":"label","type":"str","default":"he said \"hi\"\n\ttab\\done"},{"name":"max_i32","type":"i32","default":2147483647},{"name":"min_i32","type":"i32","default":-2147483648},{"name":"owner","type":"u64","default":0},{"name":"speed","type":"f32","default":12.5},{"name":"tiny","type":"f32","default":1e-05}]},{"name":"Dead","persist":"transient","fields":[]}],"events":[{"name":"hunger__feed","fields":[{"name":"amount","type":"f32","default":0.5},{"name":"at","type":"vec2","default":{"x":-1.5,"y":3}},{"name":"entity","type":"u64","default":0},{"name":"reason","type":"str","default":"why \"now\""},{"name":"urgent","type":"bool","default":false}]},{"name":"wave__spawned","fields":[]}]}
;
