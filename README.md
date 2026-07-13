# labelle-scripting

Script [labelle](https://github.com/labelle-toolkit) games in **Lua, TypeScript, Ruby, Rust, Crystal, Go, or C#** — one plugin, one contract.

```zig
// project.labelle
.plugins = .{
    .{ .name = "scripting", .repo = "github.com/labelle-toolkit/labelle-scripting",
       .version = "…", .params = .{ .language = "lua" } },
},
```

Drop scripts in the game's `scripts/` dir — the same structure Zig scripts use (numeric ordering prefixes and all, extension-keyed coexistence: `10_spawner.rb` next to `01_move.zig`; assembler ≥ v0.86.0, the legacy per-language dirs work for one release of grace) — and declare components in `components/` and events in `events/`, beside any Zig ones (`components/hunger.rb` next to `components/*.zig`, `events/hunger__feed.rb` likewise; declare-mode languages, events since assembler v0.87.0). Zig is never REQUIRED: a game can be 100% script-language (`examples/ruby-game` is, provably — CI deletes its one optional native hook and it still runs). One language per project (validated at `labelle generate`); unchosen languages cost nothing — never fetched (lua and quickjs, lazy dependencies) or never compiled (ruby, an in-repo vendor snapshot).

Every language binds the engine's **Script Runtime Contract** (`labelle-engine/contract/labelle_script.h`, `LABELLE_CONTRACT_VERSION 1`): entities, components-by-name (JSON), events (subscribe + poll-drain), queries, prefabs, input, time. Both integration families — embedded-VM (lua, ruby/mruby, typescript/QuickJS, csharp/CoreCLR) and native-compiled (rust, crystal, go) — consume the identical surface, proven end to end by the [POC](https://github.com/labelle-toolkit/labelle-engine/pull/734).

| sub-module | status |
|---|---|
| `lua` (Lua 5.4) | ✅ bootstrap done (#738) + per-frame allocation utilities (#2) — vendored Lua 5.4.8, contract-bound, tested against a mock host |
| `ruby` (mruby 3.4) | ✅ done (labelle-engine#742) — vendored mruby, controllers + Component.ref + FrameArray, tested against the same mock host; game scripts in `scripts/`, component declarations in `components/*.rb` (tools/declare-ruby, assembler ≥ v0.86.0) — end-to-end proof `examples/ruby-game` |
| `typescript` (QuickJS) | ✅ done (labelle-engine#745) — quickjs-ng 0.15, ES-module scripts, BigInt ids, typed via contract/labelle.d.ts, tested against the same mock host; game `scripts/*.ts` sources are TYPE-CHECKED and emitted at `labelle generate` by the assembler's pinned tsc 7.0.2 native binary against a `labelle-components.d.ts` generated from the game's real component registry — type errors fail generate (labelle-assembler ≥ v0.86.0, #613) — end-to-end proof `examples/ts-game` |
| `rust` (staticlib) | ✅ done (labelle-engine#741) — first native-compiled sub-module: game `scripts/` sources (module root `scripts/mod.rs`) cargo-built into the shipped crate (`native/`), `Script` trait + safe wrappers, panics caught at every FFI entry, tested against the same mock host AND end-to-end (`examples/rust-game` through the assembler's native-language splice, labelle-assembler ≥ v0.84.0; the `scripts/` dir since v0.86.0) |
| `crystal` (localized object) | ✅ done (labelle-engine#741) — second native-compiled sub-module on rust's skeleton: game `scripts/` sources (module root `scripts/game.cr`) built by `crystal build --cross-compile` + a main-localization pass into a linkable object, `Labelle::Script` class + safe wrappers, every raise rescued at every FFI entry, GC collections enabled (host-thread runtime boot), tested against the same mock host AND end-to-end (`examples/crystal-game` through the assembler's native-language splice, labelle-assembler ≥ v0.85.0; the `scripts/` dir since v0.86.0) |
| `go` (c-archive) | planned |
| `csharp` (CoreCLR) | ✅ done (labelle-engine#743) — the epic's final sub-module: game `scripts/*.cs` compiled by `dotnet publish` into a managed assembly (`native-csharp/`), loaded at runtime through the .NET hosting API (hostfxr) with `[UnmanagedCallersOnly]` entries, contract bound via `[LibraryImport]` against the host process; both deployment modes (framework-dependent / self-contained) documented below; desktop-first (mobile AOT out of v1). Components + events declared in C# (labelle-declare-csharp, #27); CI-proven end to end through the real assembler (`examples/csharp-game`: generate → declare → `dotnet publish` → run) |

## Using the lua sub-module

Zig side — register sources, wire the plugin controller (the assembler
generates exactly this from your `scripts/` dir; `registerScript` is
the seam to call yourself when embedding by hand):

```zig
const scripting = @import("labelle_scripting");

// once at boot, before setup — name = chunkname in error tracebacks
// (the game's scripts/ dir; ordering prefixes strip from the stem)
scripting.registerScript("player", @embedFile("scripts/player.lua"));

try scripting.Controller.setup(&game); // boots the VM, runs each init()
scripting.Controller.tick(&game, dt);  // each frame: inbox dispatch + update(dt)
scripting.Controller.deinit();         // runs each deinit(), closes the VM
```

Lua side — each script gets its own environment (no cross-script global
clashes) with the prelude in scope: `Entity`, `game.query`, `labelle.*`
sugar, pure-Lua `json`. Raw contract shims stay reachable as `labelle.raw_*`.

```lua
local player

labelle.on("cargo__delivered", function(ev)   -- decoded payload table
    labelle.log("got " .. ev.amount)
end)

function init()
    player = Entity.new()
    player:set("Position", { x = 0, y = 0 })  -- components as tables
end

function update(dt)
    local pos = player:get("Position")
    pos.x = pos.x + 10 * dt
    player:set("Position", pos)
    for e in game.query("Bullet", "Position") do e:destroy() end
end
```

Script errors log a full traceback through the game's sink and never kill
the tick; a script that fails to load or whose `init()` throws is evicted —
it receives no `update`/`deinit` until the next setup. Build with
`-Dlanguage=lua` (the default; the option exists so future languages slot
in additively).

**Entity ids**: ids are u64 on the host and cross into Lua as the signed
64-bit bitcast — lossless for math, comparisons, and every `labelle.*` /
`raw_*` call. But embed entity ids in payloads via `labelle.u64str(id)`
(the id becomes a JSON string) — plain `%d` would sign-flip bit-63 ids.
The decode direction needs no opt-in: `json.decode` parses integer
tokens with wrapping 64-bit arithmetic, so a u64 id arriving in an event
payload lands bit-exact and `Entity.wrap(ev.owner)` addresses the right
entity.

**Arrays**: an empty Lua table is ambiguous and encodes as the JSON
object `{}` (the contract's "all defaults"). Wrap array-typed component
fields in `labelle.array(t)` to force array form even when empty —
`{ waypoints = labelle.array({}) }` encodes as `{"waypoints":[]}` — and
`json.decode` tags the arrays it returns, so `get`→modify→`set`
round-trips preserve arrayness without re-tagging.

**Per-frame allocation** (RFC revs 14–15): the component boundary is the
real per-frame allocator — script-local temporaries are noise next to a
fresh table per `e:get` times a thousand entities times sixty frames.
The prelude ships the Zig `clearRetainingCapacity` idiom for both
halves of a hot loop:

```lua
local Hot = labelle.component("Hot", { level = 1.0, count = 0 })
local h, fa                     -- construct once, in init() (chunk scope
                                -- also runs in declare mode)
function init()
  h = {}                        -- caller-owned component buffer
  fa = FrameArray.new(1024)     -- preallocated per-frame scratch list
end

function update(dt)
  fa:clear()                    -- size back to 0; storage survives
  for e in game.query(Hot) do fa:push(e) end
  for i = 1, fa:size() do
    local e = fa:get(i)
    e:get(Hot, h)               -- REFILLS h — no per-read table
    h.level = h.level - 0.25 * dt
    e:set(Hot, h)
  end
end
```

`e:get(name, into)` refills the caller's table and returns it: top-level
fields are written, stale keys from the previous fill are cleared
(clear-all-then-fill — a `pairs` walk assigning nil, which itself
allocates nothing), nested values still allocate fresh per read (v1 —
keep hot components flat), and an absent component returns nil leaving
the table untouched. Both name spellings work (`e:get("Hot", h)` and
`e:get(Hot, h)`).

`FrameArray.new(cap)` preallocates its backing once: `push` is an
in-bounds store, `clear` resets the logical length only, and growth
happens solely when a push overflows capacity — the backing doubles, one
deliberate reallocation, counted in `growth_count()` so a warmed loop
can assert it stays flat. (Lua 5.4 has no `table.clear`; a fresh `{}`
per frame is exactly the allocation this removes.) Also: `size()`,
`capacity()`, `get(i)`/`set(i, v)` over the logical contents, and
`each(fn)` — hoist `fn`, a fresh closure per frame is itself a per-frame
allocation. One consequence of the O(1) `clear`: the backing keeps
strong references to cleared values until later pushes overwrite them
(free for the per-frame refill loop; irrelevant for numbers/ids). If an
array parked something heavy and then shrinks its fill for many frames,
`release()` drops every parked reference — the backing is overwritten
with `false`, O(capacity), still allocation-free — and keeps capacity.

One boundary to know about: Lua interns only *short* strings (≤ 40
bytes). A component whose serialized JSON exceeds that comes back from
the contract as a fresh long string on every read — allocation the
decode side cannot avoid, get-into or not. Keep hot-loop components
compact (the hot-loop test's `Hot` component is such); bulky data
belongs in components you read on change, not per frame.

What garbage remains (encode buffers, query snapshots, event payloads)
is collected on a budget: the plugin drives one incremental GC step per
Controller tick — `lua_gc(LUA_GCSTEP, budget)` at end of tick, so
collection cost smears across frames instead of piling into mid-frame
pauses. Lua 5.4's own incremental pacing stays on as the backstop; the
step only front-loads work at the tick boundary (a budget at or above
the per-tick allocation rate moves effectively all collection into that
slot). Default 64 KB/tick; `labelle.raw_gc_set_step_budget(kb)` tunes it
(0 = the collector's own basic step, negative = off, returns the
previous value) and `labelle.raw_gc_stats()` returns
`(steps, completed_cycles)`. The suite's hot-loop test pins the whole
story: 1k entities of query + get-into + set + FrameArray per tick, per-
read allocation ≈ 0 and steady-state memory flat across 100 ticks.

Cross-language, same idioms: ruby spells them `e.get_into(Klass, @h)` +
`Labelle::FrameArray` (below); typescript spells them
`e.get("Hunger", into)` + `labelle.FrameArray` (+ a reused
`Float64Array` for pure-numeric scratch) over the same contract.

## Using the ruby sub-module

Build with `-Dlanguage=ruby`. The Zig side is identical to lua — same
`registerScript`/`Controller` seam, same contract, same mock-tested
semantics — only the sources are `.rb`:

```zig
scripting.registerScript("hunger", @embedFile("scripts/10_hunger.rb"));
```

Ruby side — two tiers. Plain per-script hooks (lua parity):

```ruby
def init                      # @ivars live on a per-script receiver:
  @player = Labelle::Entity.create      # two scripts defining the same
  @player.set("Position", x: 0, y: 0)   # hooks never collide
  Labelle.on("cargo__delivered") { |ev| Labelle.log("got #{ev[:amount]}") }
end

def update(dt)
  pos = @player.get("Position")         # symbol-keyed Hash
  pos[:x] += 10 * dt
  @player.set("Position", pos)
end
```

Subscribe inside `init` (or controller `setup`), not at file scope — a
file-scope block captures `main`, not your script's receiver, so your
@ivars would not be visible in it. Payloads arrive as symbol-keyed
Hashes; `Labelle.emit("turret__fired", turret: id)` is kwargs→JSON.

Controllers — the structured tier (auto-registered by subclassing,
instantiated in file-prefix order, `setup`/`tick(dt)`/`teardown` with
teardown in reverse order):

```ruby
Hunger = Labelle::Component.ref("Hunger", :level, :starving)

class HungerController < Labelle::Controller
  def setup
    @h = Hunger.new                 # ONE cached Struct-backed view
    on("hunger__feed") { |ev| feed(ev[:entity], ev[:amount] || 0.5) }
  end

  def tick(dt)
    each("Hunger", "Worker") do |e|
      e.get(Hunger, into: @h)       # REFILLS the cached instance
      @h.level -= 0.02 * dt
      e.set(@h)                     # writes back to THIS entity
    end
  end

  def feed(id, amount)
    # same-VM public API for other ruby code
  end
end
```

`Component.ref` builds a Struct-backed class whose fields map to the
engine component's JSON keys; `get(Klass, into:)` decodes INTO the
existing instance (string-name forms `e.get("Hunger")` → Hash and
`e.set("Hunger", h)` also work).

**Declaring components in ruby** (one DSL, two consumers — the lua
component-ref rule, ruby spelling). Declaration files live where their
kind lives — in `components/`, beside the Zig ones (the components dir
is extension-keyed and mixed-language; assembler ≥ v0.86.0):

```ruby
# components/hunger.rb — a components/*.zig may sit right beside it
Hunger = Labelle.component "Hunger", level: 0.875, starving: false
```

is a SCHEMA DECLARATION at build time — `labelle generate` runs the
ruby declare runner (`tools/declare-ruby`, built by `zig build
labelle-declare-ruby`, the lua extractor's per-language sibling) over
the game's `components/*.rb` files and scripts (a chunk-scope
declaration inside a script stays legal — both feed the extractor) and
the assembler codegens a real Zig registry component from the extracted
schema (field types inferred from the defaults: Float→f32, Integer→i32,
bool, String→str, `{ x:, y: }`→vec2; persist policy via a trailing
options hash, exactly like lua's third argument: `Tag =
Labelle.component "Tag", { kind: "none" }, persist: "transient"`). At
RUNTIME the same line evaluates to a `Component.ref`-EQUIVALENT view
class built from the spec's keys — spec values and options are the
build-time contract and are ignored, because the component already
exists in the game's registry. Components-dir files are embedded and
registered BEFORE the `scripts/` entries, so the view constants they
define exist by the time scripts load (`examples/ruby-game` is the
running proof: its controller uses the declared `Hunger` with no
`Component.ref` line). An empty spec (`Labelle.component "Dead", {}`)
yields a zero-field marker view. `Component.ref` stays the
explicit-fields spelling of the same class — the two are
interchangeable. In declare mode only `Labelle.component` is live:
every other `Labelle.*` call (and `Component.ref`, `Entity.create`,
`FrameArray.new`, ...) is a no-op returning a sentinel the extractor
REJECTS in spec positions — helpers-as-data fail the build — while
`class Foo < Labelle::Controller` bodies define cleanly (nothing runs).
Each script is extracted in a fresh interpreter, so top-level defs,
constants and even a clobbered `Labelle` never leak between files.

**Per-frame allocation** (the mruby homework): mruby's `Array#clear`
FREES the heap buffer, so per-frame scratch cleared with `.clear`
reallocates every tick — use `Labelle::FrameArray.new(cap)` (`<<` is
in-bounds index assignment, `clear` is `len = 0`, growth only on
overflow and visible via `growth_count`). The GC arena is saved/restored
around every VM entry. For strictly zero-allocation hot loops use the
positional `e.get_into(Klass, @h)` + `e.set(@h)` pair — the kwarg
spelling `get(K, into: @h)` costs ~2 small objects per call because
mruby materializes keyword args (the suite's zero-alloc test pins the
strict path flat on a live-object counter across 100 ticks with the GC
disabled).

**Entity ids**: same rule as lua — ids are the signed 64-bit bitcast;
embed them in payloads via `Labelle.u64str(id)`. The decode direction is
automatic (the Zig-side JSON codec parses integer tokens with wrapping
64-bit arithmetic; mruby itself raises on integer overflow, which is why
the codec lives in Zig). **Arrays vs objects**: nothing to learn — Hash
and Array are distinct types, `{}` and `[]` round-trip natively (lua's
`labelle.array` has no ruby counterpart because the ambiguity doesn't
exist).

**Sandbox posture**: the vendored gembox is pure-language core gems +
struct/metaprog/error/compiler — no io, socket, dir, eval, time, sleep
or exit (see vendor/mruby/README.md, which also carries the packaging
TODO: move the in-repo vendor snapshot to a lazy prebuilt tarball once a
labelle-hosted one exists — mruby has no amalgamation and its upstream
build needs host ruby+rake, which consumers never see).

## Declaring events in lua and ruby

Custom bus events follow the component pattern — one line, two
consumers (labelle-engine#772). Declaration files live where their kind
lives: `events/*.rb|lua` beside `events/*.zig` (the events dir is
extension-keyed and mixed-language, like `components/`; the assembler
collects them since v0.87.0, and `examples/ruby-game/events/hunger__feed.rb`
is the live file-form example — the event the whole example fans out
over):

```ruby
# events/hunger__feed.rb — next to events/other_event.zig
HungerFeed = Labelle.event "hunger__feed", entity: Labelle.id, amount: 0.5
```

```lua
-- events/hunger__feed.lua
local HungerFeed = labelle.event("hunger__feed", { entity = labelle.id, amount = 0.5 })
```

At BUILD time the line is a SCHEMA DECLARATION: `labelle generate` runs
the language's declare runner over it and the assembler codegens the
schema into ONE generated `scripting_events.zig` at the target root
(staged convention dirs are live links, so per-event files can't be
materialized into `events/`) — the generated game's event union,
sidecars and routing come out exactly as if the `.zig` file existed.
One consequence for NATIVE consumers: a game-root hook consuming a
declared event spells its payload parameter `anytype` instead of
importing a per-event file — dispatch stays comptime-typed and field
access is unchanged (`examples/ruby-game/hooks/feed_watcher.zig` is the
live example: a Zig hook consuming the ruby-declared event). Field types
infer from the defaults exactly like components (Float→f32,
Integer→i32, bool, String→str, `{ x:, y: }`→vec2) with one addition:
**`Labelle.id`** (lua: `labelle.id`) marks an entity-id field —
`{"type":"u64","default":0}` in the schema, since no plain script value
can spell u64. The marker is legal in component specs too (components
gain u64 fields the same way), takes no arguments (v1 has no id(value)
constructor — id fields always default 0), and returns plain `0` at
runtime so the same spec line evaluates clean in both modes. Events
have NO options argument — they are never persisted, so where a
component takes `persist:` a third argument to `Labelle.event` is a
build error. A payloadless event is an explicit empty spec
(`Labelle.event "wave__spawned", {}`); payloads cap at 32 fields (the
view fast path's ceiling); duplicate event names across files fail the
build naming the first file; and events are their OWN namespace — an
event may share a component's name.

At RUNTIME the same call validates the name and returns it — the frozen
name string (a plain immutable string in lua) — so the one constant
drives both legs of the bus:

```ruby
Labelle.on(HungerFeed) { |ev| feed(ev[:entity], ev[:amount]) }
Labelle.emit(HungerFeed, entity: Labelle.u64str(e.id), amount: 0.5)
```

Event files register BETWEEN components and scripts (components →
events → scripts, pinned), and ruby top-level constants are VM-global —
so `HungerFeed` is already defined when every script chunk loads, and a
FILE-SCOPE `Labelle.on(HungerFeed)` in another file is legal (the
declare phase tolerates the cross-file reference too: its
per-chunk-isolated stub resolves unknown constants to the inert
sentinel, so the subscription no-ops at extract time and still fails
pointedly if a typo'd constant lands in a spec position). The plain
string spelling stays equivalent — the constant IS the name.

One file may declare several events (stem == name is style, not
enforced), and a chunk-scope declaration inside a regular script stays
legal — both feed the extractor. TypeScript games keep Zig events for
now (no TS declare runner exists yet).

## Using the typescript sub-module

Build with `-Dlanguage=typescript` (embeds [quickjs-ng](https://github.com/quickjs-ng/quickjs)
0.15, a pinned lazy dependency compiled only when selected). The Zig side
is identical to lua/ruby — same `registerScript`/`Controller` seam, same
contract, same mock-tested semantics — only the sources are JavaScript:

```zig
scripting.registerScript("player", @embedFile("scripts/player.js"));
```

Scripts are **plain JS at runtime** — and you author them in
**TypeScript**: since labelle-assembler v0.86.0 (#613,
labelle-engine#745), `.ts` sources in the game's `scripts/` dir are
TYPE-CHECKED and emitted to plain-JS ES modules at `labelle generate` by
the assembler's pinned **tsc 7.0.2 native binary** (fetched once per
machine into the shared `~/.labelle/tools/typescript/` cache from a
hash-pinned registry tarball — no node/npm anywhere; `.js`-only projects
never touch the toolchain). **Type errors fail generate** with tsc's
diagnostics relayed verbatim, and the check runs against two declaration
files: `contract/labelle.d.ts` (this repo — the whole script API) plus a
**generated `labelle-components.d.ts`** built from the game's REAL
component registry (`interface LabelleComponents` + keyof-constrained
`Entity.get/set` overloads; i64/u64 fields type as `bigint`) — so
`e.get("Hunger", h)` types `h.level` as `number` and a typo'd `h.levl`
is a TS2551 at generate, before anything builds. `examples/ts-game` is
the running proof.

Editor-side authoring (no assembler in the loop) works for both
extensions:

- **.js scripts**: put `// @ts-check` at the top and add a
  `jsconfig.json` whose `"include"` lists your scripts plus
  `labelle.d.ts` (copy it or point at the resolved package's
  `contract/` dir) — your editor checks every call against the real API.
- **.ts scripts**: your editor picks the same declarations up; after
  any generate, `<target>/tsconfig.json` IS the generated config —
  `tsc -p <target>/tsconfig.json` reproduces CI's exact check, the
  generated `labelle-components.d.ts` included.

Script side — each script is an **ES module**: module scope is the
isolation boundary (top-level `let`/`const`/`function` are private to the
file; two scripts defining `update` never collide) and lifecycle hooks
are the module's **exports** — an unexported `function update` is
module-private and never called. Modules are strict mode by spec;
`import` is refused (scripts arrive through `registerScript`, never
disk); top-level `await` is rejected at load.

```js
// @ts-check
let player = null;

labelle.on("cargo__delivered", (ev) => {   // decoded payload object
  labelle.log(`got ${ev.amount}`);
});

export function init() {
  player = Entity.create();
  player.set("Position", { x: 0, y: 0 });  // components as objects
}

export function update(dt) {
  const pos = player.get("Position");
  pos.x += 10 * dt;
  player.set("Position", pos);
  for (const e of game.query("Bullet", "Position")) e.destroy();
}
```

Script errors log `"<Error>: <message>"` plus the JS stack (with
`file:line` locations) through the game's sink and never kill the tick;
a script that fails to load or whose `init()` throws is evicted — its
event handlers are purged with it (`export function deinit` never runs
for an evicted script).

**Entity ids are BigInt** — the one JS-specific rule worth learning.
Numbers lose exactness past 2^53 and u64 ids use bit 63, so `e.id` is a
BigInt holding the TRUE unsigned value (`${e.id}` prints it correctly —
no lua/ruby signed-bitcast caveat). Consequences:

- compare ids with `===` between BigInts; a Number-held small id from a
  payload compares equal via `==`, or normalize first:
  `Entity.wrap(ev.owner).id === e.id`;
- id arithmetic is BigInt arithmetic (`let sum = 0n`) — mixing BigInt
  and Number in `+` is a TypeError by design;
- embed ids in payloads directly: `labelle.emit("fired", { owner: e.id })`
  encodes the BigInt as the contract's unsigned decimal
  (`labelle.u64str(id)` still ships for cross-language parity);
- **never** use `JSON.parse`/`JSON.stringify` for payloads —
  `labelle.json_decode`/`labelle.json_encode` are the id-exact codec
  (decode materializes integer tokens past 2^53 as BigInt; stringify
  would throw on BigInt). Otherwise the codec keeps JSON.stringify's
  semantics (undefined-valued keys omitted, functions skipped in
  objects), plus sorted keys so encodings are byte-stable.

**Arrays vs objects**: nothing to learn — `{}` and `[]` are distinct
types and round-trip natively (lua's `labelle.array` has no JS
counterpart because the ambiguity doesn't exist).

**Per-frame allocation**: QuickJS is reference-counted with a cycle
collector on top — acyclic garbage frees at the last reference, so there
is no per-frame GC step to budget and a net-zero tick leaves the live
allocation count EXACTLY flat (the suite pins 100 working ticks flat on
`JS_ComputeMemoryUsage.malloc_count`). The idioms that keep a hot loop
net-zero:

- `e.get("Hunger", into)` — REFILLS a caller-owned object in place and
  returns it (scalar fields cross as immediates, no fresh object per
  read); pair with `e.set("Hunger", into)`;
- `labelle.FrameArray` for per-frame lists — `clear()` resets the
  logical length and KEEPS the backing (whether `arr.length = 0`
  retains storage is engine-internal, so never rely on it); growth only
  on overflow and visible via `growthCount`;
- a reused `Float64Array` for pure-numeric scratch — fixed capacity by
  construction, elements are raw doubles (no boxing at all).

Design: `RFC-LANGUAGE-PLUGINS.md` (labelle-engine#730) · epic: labelle-engine#237

## Using the rust sub-module

Build with `-Dlanguage=rust` — the first **native-compiled** sub-module
(labelle-engine#741): there is no VM and nothing embeds. Your game's
`scripts/` dir (`.rs` sources, module root `scripts/mod.rs`) is compiled
by cargo into the crate this plugin ships (`native/` — Cargo manifest,
the `labelle` module, the entry-point glue) as its `game` module,
producing `liblabelle_rust_scripts.a`, which links into the game binary.
The contract header IS the binding (the POC's finding): the crate
declares the `labelle_*` symbols `extern "C"` and they resolve against
the host's exports in the same binary — zero bindings layer, zero
indirection. The plugin's Zig side shrinks to a thin dispatcher onto the
glue's `labelle_rs_*` entry points (`src/rust/vm.zig`), driven by the
same Controller as every VM language.

Your `scripts/mod.rs` implements one convention entry point; scripts are
plain structs implementing the `Script` trait, state in their fields:

```rust
use crate::labelle::{self, EntityId, Script, Scripts};

pub fn register(scripts: &mut Scripts) {
    scripts.add("player", Box::new(Player::default()));
}

#[derive(Default)]
struct Player {
    e: EntityId,
    pos: Vec<u8>, // reused every tick — steady state allocates nothing
}

impl Script for Player {
    fn init(&mut self) {
        self.e = labelle::create_entity();
        labelle::set_component(self.e, "Position", r#"{"x":0,"y":0}"#);
        labelle::subscribe("cargo__delivered");
    }
    fn on_event(&mut self, name: &str, payload: &str) {
        if name == "cargo__delivered" {
            labelle::log(&format!("got {}", payload));
        }
    }
    fn update(&mut self, _dt: f32) {
        labelle::get_component_into(self.e, "Position", &mut self.pos);
        // parse, mutate, set — ids are u64 END TO END (no BigInt/bitcast
        // caveats: rust's u64 carries bit-63 ids exactly).
    }
}
```

**Panics never cross the FFI boundary.** Every glue entry point (and
every script hook individually) runs under `catch_unwind`: a panic in
`init` logs and EVICTS the script (no `update`/`deinit` on
half-initialized state); a panic in `update`/`on_event` logs every tick
and the script stays; siblings always keep running — the same isolation
story as a lua `error()`, minus the traceback (you get the panic
message and location on stderr via the standard panic hook). The crate
pins `panic = "unwind"` because of this; don't switch it to abort.

**Per-frame allocation** is the rust freebie: the wrappers take
caller-owned `Vec`s (`get_component_into`, `query_into`, `poll_into`),
`clear()` retains capacity, growth is required-size-driven and happens
at most once — hold buffers in script fields and the steady state is
allocation-free (the suite pins 100 working ticks with zero capacity
movement).

**No console eval**: compiled code can't be evaluated — the studio
Script Console gets a documented `ok:false` refusal.

**End-to-end wiring** (generate → cargo → link) rides the assembler's
native-language splice (labelle-assembler ≥ v0.84.0; the `scripts/`
convention dir since v0.86.0 — the legacy `rust/` dir keeps working for
one release of grace): it stages your `scripts/` as a LIVE LINK over
the staged package's `native/src/game/` (edit a `.rs`, rerun
`zig build` — no re-generate), passes `-Dlanguage=rust`, and runs the
build step declared in this repo's `plugin.labelle` (`.language_builds`
— cargo → staticlib → `addObjectFile`, desktop-first).
`examples/rust-game` is the running proof. Needs a rust toolchain
(rustc ≥ 1.82) wherever the game builds.

## Using the crystal sub-module

Build with `-Dlanguage=crystal` — the second **native-compiled**
sub-module (labelle-engine#741), on rust's exact skeleton. One v1
scope rule first: game scripts should stick to crystal's core stdlib
(`Regex` included — pcre2 ships in the declared system libs). The
OPTIONAL stdlib native deps (OpenSSL, YAML, Compress/zlib, …) need
system libraries the plugin's fixed manifest list cannot predict —
using them fails at final link with unresolved symbols naming the
library; generate-time capture of crystal's printed link line is the
planned follow-up. Your game's
`scripts/` dir (`.cr` sources, module root `scripts/game.cr`) is
compiled by `crystal build --cross-compile` together with the sources
this plugin ships (`native-crystal/` — the `Labelle`
module and the entry-point glue) as its `Game` module; because crystal
has no `--no-main`, a second build step localizes the object's own
`main` (and every other symbol) away — `ld -r -exported_symbols_list`
on macOS, `objcopy --keep-global-symbols` on linux — leaving exactly
the `labelle_cr_*` entry points, and the resulting object links into
the game binary. The contract header IS the binding, exactly as for
rust: `lib LibLabelle` declares the `labelle_*` symbols and they
resolve against the host's exports in the same binary. The plugin's
Zig side is the same thin dispatcher (`src/crystal/vm.zig`), plus one
crystal-only leg: a ONE-TIME runtime boot at first setup (`GC.init` +
`Crystal.init_runtime` + `Crystal.main_user_code` — GC stack
registration on the game's main thread and the program's top-level
constant initializers; the labelle-engine#734 POC's sharp edges, all
institutionalized in the glue).

Your `scripts/game.cr` implements one convention entry point; scripts
are classes inheriting `Labelle::Script`, state in instance vars:

```crystal
class Player < Labelle::Script
  @e : Labelle::EntityId = 0_u64
  @pos = Labelle::Buffer.new # reused every tick — steady state allocates nothing

  def init : Nil
    @e = Labelle.create_entity
    Labelle.set_component(@e, "Position", %({"x":0,"y":0}))
    Labelle.subscribe("cargo__delivered")
  end

  def on_event(name : String, payload : String) : Nil
    Labelle.log("got #{payload}") if name == "cargo__delivered"
  end

  def update(dt : Float32) : Nil
    Labelle.get_component_into(@e, "Position", @pos)
    # parse from @pos.to_slice, mutate, set — ids are UInt64 END TO END
    # (no BigInt/bitcast caveats; never let one near to_i64 or a float).
  end
end

module Game
  def self.register(scripts : Labelle::Scripts)
    scripts.add "player", Player.new
  end
end
```

**A failed runtime boot fails loudly and stays failed.** The boot
reports which stage raised (GC.init / init_runtime / top-level
initialization — a game constant initializer throwing lands here);
setup errors, no scripts run, and crystal scripting stays disabled for
the process — a partial boot cannot be retried (a top-level re-run
over the half-initialized first pass crashes in GC collections; the
boot suite pins this). Fix the reported stage and restart.

**Exceptions never cross the FFI boundary.** Every glue entry point
(and every script hook individually) runs under begin/rescue: a raise
in `init` logs and EVICTS the script; a raise in `update`/`on_event`
logs every tick and the script stays; siblings always keep running —
the same isolation story as rust's panics (an escape would kill the
process: crystal finds no handler in the host's foreign frames). You
get the exception class and message in the game log; backtraces are
deliberately dropped (their decode reads the executable image — an
embedding hazard for near-zero value).

**The GC runs with collections enabled** — the boot registers the host
thread's stack with bdw-gc, and the suite forces `GC.collect` on every
tick of a churn workload to keep it that way. Two rules of the road:
no top-level statements with world side effects (the top level runs
once at runtime boot, not at script setup), and hold reused
`Labelle::Buffer`s in instance vars (`get_component_into`,
`query_into` grow them at most once — the rust `Vec` idiom, crystal-
spelled).

**No console eval**: compiled code can't be evaluated — the studio
Script Console gets a documented `ok:false` refusal.

**End-to-end wiring** (generate → crystal build → localize → link)
rides the assembler's native-language splice (labelle-assembler ≥
v0.85.0, the crystal row; the `scripts/` convention dir since v0.86.0 —
the legacy `crystal/` dir keeps working for one release of grace): it
stages your `scripts/` as a LIVE LINK
over the staged package's `native-crystal/src/game/` (edit a `.cr`,
rerun `zig build` — no re-generate), passes `-Dlanguage=crystal`, and
runs the steps declared in this repo's `plugin.labelle`
(`.language_builds` — crystal build → `ld -r`/objcopy picked by the
per-step `.os` allowlists → `addObjectFile`, desktop-first).
`examples/crystal-game` is the running proof. Needs a crystal
toolchain (≥ 1.16 — `Crystal.init_runtime`) wherever the game builds —
generate included: resolving `{crystal_env:CRYSTAL_LIBRARY_PATH}` runs
`crystal env`.

**A stability note, stated plainly**: crystal has no public embedding
API — `Crystal.init_runtime` and `Crystal.main_user_code` are
`:nodoc:` internals and may change between crystal releases. That is
the deal the whole native-crystal story rides on (the POC chose them
because nothing supported exists), and the guard is the version pin:
CI builds against a pinned crystal (1.17), the boot handshake fails
fast on drift, and any toolchain bump goes through this repo's full
suite before consumers see it. Treat crystal version bumps as
deliberate, reviewed changes — never incidental.

## Using the csharp sub-module

Build with `-Dlanguage=csharp` — the language-plugins epic's final
sub-module (labelle-engine#743). C# is **CoreCLR-hosted**: the .NET
runtime is embedded in the game process (joining lua/ruby/typescript in
the embedded-runtime family), but game scripts are *compiled* C#, not
interpreted source — so the dispatch shape matches the compiled family
(rust/crystal): registered *sources* are refused, and the plugin drives
the managed side through the Controller-tier entry points.

Your game's `scripts/*.cs` are compiled — together with the plugin's
shipped `Labelle` + `Glue` module (`native-csharp/`) — into a managed
assembly `labelle_csharp_scripts.dll` by `dotnet publish` (the plugin's
declared `.language_builds` step). At runtime `src/csharp/vm.zig` loads
that assembly through the .NET hosting API:

1. locate `hostfxr` (the app dir first for self-contained, else
   `$DOTNET_ROOT` / the platform's default install);
2. `hostfxr_initialize_for_runtime_config(labelle_csharp_scripts.runtimeconfig.json)`;
3. `hostfxr_get_runtime_delegate(load_assembly_and_get_function_pointer)`;
4. resolve each `[UnmanagedCallersOnly]` entry in `Glue` to a bare C
   function pointer — no marshalling thunk.

The contract flows the other way exactly like rust/crystal: `Labelle.cs`
declares the `labelle_*` symbols with **`[LibraryImport]`** and a
`DllImportResolver` binds them against the **host process**
(`NativeLibrary.GetMainProgramHandle()`), so a C# `Labelle.Log(...)` lands
in the same game log sink a Zig script would. **The host binary must
export the contract symbols** in its dynamic symbol table (the repo's test
binary is linked `rdynamic`; a shipped game's assembler-generated main must
do the same — `-rdynamic` on ELF, an export table on PE/COFF).

Your scripts are plain classes deriving `Script` (global namespace — no
`using` needed), registered by a `Game.Register` convention:

```csharp
public static class Game {
    public static void Register(Scripts scripts) {
        scripts.Add("player", new Player());
    }
}

public sealed class Player : Script {
    public override void Init() { Labelle.Log("hello from C#"); }
    public override void Update(float dt) { /* … */ }
    public override void OnEvent(string name, string payload) { /* … */ }
    public override void Deinit() { }
}
```

Ids are `ulong` end to end (no bitcast/BigInt caveat). Contract wrappers
follow the family's **buffer-reuse idiom**: `GetComponentInto` /
`QueryInto` / `PollInto` take a caller-owned `ref byte[]` (or
`List<EntityId>`) held in a field and grow it at most once via the
contract's required-size legs. Exceptions are contained at every FFI
entry (a throw out of an `[UnmanagedCallersOnly]` method into foreign
frames is UB): Init throw → logged + evicted; Update/OnEvent throw →
logged every time, script stays; `Register` throw → all-or-nothing
rollback — the same isolation story as rust's panics / crystal's raises.

**Declaring components and events in C#** (labelle-scripting#27). Author a
component or event as a `record` carrying `[LabelleComponent]` or
`[LabelleEvent]` (global namespace — no `using`), whose public instance fields
are the schema and whose field initializers are the declared defaults:

```csharp
[LabelleComponent]
record Hunger
{
    public double level = 1.0;   // double|float → f32; formats at f64 precision
    public bool starving = false;
}

[LabelleComponent(Persist.Transient)]
record Dead;

[LabelleEvent]
record hunger__feed
{
    public ulong entity = 0;     // ulong → u64 (the entity-id type)
    public double amount = 0.5;
}
```

Type map: `double`|`float`→f32, `int`→i32, `bool`, `string`→str, `Vec2`→vec2,
`ulong`→u64. At `labelle generate` the assembler runs `labelle-declare-csharp`
(a `dotnet` compile-and-run probe) over the game's `components/*.cs` +
`events/*.cs`, extracts the schema, and codegens the game's component registry /
event union — exactly as a `components/*.zig` would, and byte-identical to
lua/ruby/rust/crystal/ts. Drop `components/*.zig`: a C# game reaches the same
zero-authored-`.zig` purity (see `examples/csharp-game`, CI-proven).

**A first-class Visual Studio project** (labelle-assembler#617). `labelle
generate` also emits a dev `.csproj` at the game root so you can open the game
in Visual Studio / Rider / VS Code with full IntelliSense and build-in-place:
it globs your `scripts/` + `components/` + `events/` and references the shipped
`Labelle` surface, so `Labelle.*`, `Script`, `[LabelleComponent]`, `Vec2`, …
all resolve as you edit the files you ship. It is a dev aid, regenerated each
generate — the real build stays the `.language_builds` `dotnet publish` above.

**Deployment modes** (both documented, both ride the same hosting call —
they differ only in where hostfxr and the shared framework live):

- **Framework-dependent** (the default; smallest artifact): `dotnet
  publish -c Release --self-contained false`. Needs a globally installed
  .NET runtime on the player's machine (matching the `TargetFramework`);
  `hostfxr` resolves from the system install (`$DOTNET_ROOT` / the
  platform default). This is what CI and `zig build test` verify.
- **Self-contained** (no prerequisite; larger artifact): `dotnet publish
  -c Release --self-contained true -r <rid>` (e.g. `win-x64`,
  `linux-x64`, `osx-arm64`). Ships the runtime — including `hostfxr` —
  beside the binary; `src/csharp/vm.zig` finds it in the app directory
  first, so no system .NET is required.

The VM reads `LABELLE_CS_ASSEMBLY_DIR` to locate the assembly (the
assembler stages it there); absent that, it looks beside the running
executable. Needs the .NET SDK (≥ 7 for the `[LibraryImport]` source
generator) wherever the game's C# is built.

**End-to-end wiring** (generate → dotnet publish → hostfxr load) is the
assembler's csharp splice — a follow-up to labelle-engine#743 (no
released assembler row yet), so `examples/csharp-game` is
documentation-first while the plugin side is verified by `zig build test`
(the csharp suite drives the managed assembly through hostfxr against the
mock host). Game scripts target the refined `scripts/*.cs` convention;
legacy per-language `csharp/` dirs are a transition compatibility note.

**Desktop-first**: Windows / macOS / Linux. Mobile is explicitly out of
v1 — iOS forbids JIT, so a mobile C# story is a NativeAOT
(`[UnmanagedCallersOnly]` compiled ahead of time, linked like the rust
family) follow-up, not this ticket.

## Studio Script Console (eval)

The plugin handles the studio Script Console's
`{plugin: "scripting", command: "eval", params: {code}}` command
(labelle-scripting#4, console UI labelle-studio#78). Two halves:

- **Eval core** (`Controller.evalCommand(code)` / `handleEvalCommand`,
  src/root.zig + each backend's `Vm.evalConsole`) — evaluates the string
  in the active VM's PERSISTENT console environment (`x = 5` on one eval,
  `x` on the next: lua uses a registry-kept session `_ENV` with
  `__index = _G`, ruby reuses one compile context — mruby's mirb-style
  top-level-locals keep — and typescript evaluates global-mode on the
  shared globals). Results render via each language's tostring/inspect/
  JSON.stringify; errors come back with the full traceback and NEVER
  kill the VM or the tick. The response is bounded JSON
  (`{"ok":true,"value":…}` / `{"ok":false,"error":…}`, 4096-byte cap,
  `…`-marked truncation) — all of it tested here against the mock world.
- **Hook shim** (`packs/scripting_console/hooks/console_eval.zig`, wired
  by `plugin.labelle`'s `.packs`) — the assembler folds this bundled
  pack's hook into the generated game's `GameHooks`, subscribing it to
  `engine__editor_plugin_command`. It name-filters the broadcast, calls
  the core, and answers through `engine.plugin_command.respond`
  (labelle-engine#758, engine ≥ 2.5.0); on engines with the event but
  without the response channel the `@hasDecl` gate degrades to the
  script log. Compiled only inside generated games — this repo's tests
  parse + AstGen-check it and pin its convention-facing names.

## Examples

- **`examples/ruby-game/`** — a headless (null-backend) game whose
  `scripts/` ruby files drive the real engine end-to-end through the
  Script Runtime Contract — and the toolkit's first **provably 100%
  ruby game** (labelle-engine#772: every shipped language must be able
  to go fully selected-language). Scripts, COMPONENTS and the custom
  EVENT are all `.rb` in the labelle-engine#237 convention layout:
  ordering-prefixed scripts (`10_spawner.rb`, `20_hunger_controller.rb`
  — stems strip, prefixes order registration) beside an unnumbered one
  (`feed_watcher.rb`), the Hunger and Worker components DECLARED IN
  RUBY (`components/hunger.rb` with defaults, `components/worker.rb`
  the zero-field tag), and the `hunger__feed` bus event DECLARED IN
  RUBY too (`events/hunger__feed.rb`, one `Labelle.event` line —
  assembler ≥ v0.87.0 codegens the real event union entry from its
  schema). The transcript's 0.875-seeded decay chain proves the
  declared component defaults traveled through the ECS; the
  registration order is components → events → scripts, so the declared
  `HungerFeed` constant is VM-global before any script loads —
  `scripts/feed_watcher.rb` subscribes with the CONSTANT while the
  spawner emits by plain string, both spellings on one bus. On top: the
  `#742` HungerController pattern (the declared `Hunger` view +
  `get(…, into:)` + `set` — no `Component.ref` line), THREE
  `hunger__feed` subscribers off one emit (the controller, the
  pure-ruby top-level `scripts/feed_watcher.rb`, and the native
  game-root Zig hook `hooks/feed_watcher.zig` consuming the
  RUBY-DECLARED event with an `anytype` payload param), an
  `engine__tick` builtin subscription, `FrameArray` in the hot loop,
  and plain top-level hooks. `hooks/feed_watcher.zig` is the example's
  ONLY `.zig` — the OPTIONAL native escape hatch, never load-bearing:
  CI's purity variant scratch-copies the example, DELETES `hooks/`,
  regenerates and reruns green (the same transcript minus exactly
  `ZIG_FEED_SEEN_0.5`), proving a zero-Zig ruby game builds and runs.
  Pins: the scripting plugin `local:../..` (THIS checkout — every CI
  run exercises the current tree, declare tool included),
  core/engine/gfx registry releases, a sibling `labelle-null` clone
  (its bind touchpoint is unreleased), and a pinned labelle-assembler
  release binary (≥ v0.87.0). CI generates (asserting the generated
  `scripting_components.zig` + `scripting_events.zig`, the
  components → events → scripts registration order, and the
  one-optional-`.zig` purity inventory), builds, runs
  `LABELLE_NULL_FRAMES=5` and diffs the ordered `RUBY_*`/`ZIG_*`
  transcript — ruby's permanent regression net (labelle-scripting#10).
  Recipe + assertions: `.github/workflows/ci.yml` → `ruby-example`;
  timeline: `examples/ruby-game/scripts/20_hunger_controller.rb`.

- **`examples/rust-game/`** — the NATIVE-COMPILED counterpart
  (labelle-engine#741): the SAME hunger sawtooth, `scripts/`
  Script-trait structs instead of ruby (module root `scripts/mod.rs` —
  the same convention dir, the native family's fixed-name spelling) —
  so the transcripts diff token-for-token and the cross-language story
  is visible by eye (ruby's carries one extra token, its pure-ruby
  feed-watcher's). No VM, nothing embeds: the assembler's
  native-language splice (labelle-assembler ≥ v0.84.0; the `scripts/`
  dir since v0.86.0) links `scripts/` over the staged plugin package's
  `native/src/game/` (a live link — edits rebuild without
  re-generating) and the plugin's declared `.language_builds` cargo
  step compiles it into `liblabelle_rust_scripts.a`, linked into the
  game binary where the `labelle_*` contract symbols resolve against
  the host's exports. The scripts show the family's idioms: buffer
  reuse at every contract boundary (`get_component_into` /
  `query_into` into field-held `Vec`s — `clear()` retains capacity,
  pinned flat by `RUST_BUFFERS_OK`), u64 ids end to end, cross-script
  `hunger__feed` + `engine__tick` over the same bus, and the same
  game-root Zig hook consuming the same emit natively. CI generates
  (asserting NO `registerScript` — the family's signature), cargo-
  builds, runs `LABELLE_NULL_FRAMES=5` and diffs the ordered
  `RUST_*`/`ZIG_*` transcript — the native family's permanent
  regression net. Recipe + assertions: `.github/workflows/ci.yml` →
  `rust-example`; timeline: `examples/rust-game/scripts/mod.rs`.

- **`examples/crystal-game/`** — the SECOND native-compiled example
  (labelle-engine#741), rust-game's crystal twin: the SAME hunger
  sawtooth, `scripts/` `Labelle::Script` classes (module root
  `scripts/game.cr`) — the three transcripts diff token-for-token
  across the family boundary. The assembler's
  crystal splice (labelle-assembler ≥ v0.85.0; the `scripts/` dir since
  v0.86.0) links `scripts/` over
  the staged plugin package's `native-crystal/src/game/` (the same
  live link) and the plugin's declared `.language_builds` steps run
  the two-step recipe: `crystal build --cross-compile`, then the
  per-OS main-localization the steps' `.os` allowlists select
  (`ld -r` + exported-symbols list on macOS, `objcopy
  --keep-global-symbols` on linux — CI pins that a linux generate
  emits ONLY the objcopy step), linked as
  `labelle_crystal_scripts_lib.o` with the crystal runtime's system
  libs and the `{crystal_env:CRYSTAL_LIBRARY_PATH}`-derived search
  paths. The scripts show the family's idioms crystal-spelled: reused
  `Labelle::Buffer`s in instance vars (grow-once wrappers, parse from
  `to_slice` — pinned settled by `CRYSTAL_BUFFERS_OK`; the Buffer
  pair carries the pin since Array capacity is not introspectable),
  UInt64 ids end to end, cross-script `hunger__feed` + `engine__tick`
  over the same bus, and the same game-root Zig hook consuming the
  same emit natively. CI generates (asserting NO `registerScript`),
  crystal-builds, runs `LABELLE_NULL_FRAMES=5` and diffs the ordered
  `CRYSTAL_*`/`ZIG_*` transcript — crystal's permanent regression
  net. Recipe + assertions: `.github/workflows/ci.yml` →
  `crystal-example`; timeline: `examples/crystal-game/scripts/game.cr`.

- **`examples/ts-game/`** — the TYPED example (labelle-engine#745,
  labelle-assembler#613): the SAME hunger sawtooth, `scripts/` `.ts`
  ES modules — the transcripts diff token-for-token against ruby's
  (one deliberate tail delta: no controller tier means per-script
  deinits run in registration order, so `TS_DEINIT` precedes
  `TS_CTRL_DONE`). At `labelle generate` the assembler's transpile
  phase (≥ v0.86.0) resolves the pinned **tsc 7.0.2 native binary**
  from the shared tool cache (`~/.labelle/tools/typescript/` —
  hash-pinned registry tarball, no node/npm), generates
  `labelle-components.d.ts` from the game's REAL component registry
  (`"Hunger": { level: number; starving: boolean }` out of
  `components/hunger.zig` — typescript has no declare mode, so
  components stay Zig and the typed DIRECTION inverts ruby's),
  type-checks strict, and embeds the emitted plain-JS twins. The
  scripts are visibly typed: the cached `into` view and a helper
  parameter are annotated `LabelleComponents["Hunger"]`, entity ids
  travel as BigInt end to end, and payload fields narrow from
  `JsonValue`. Same three-subscriber `hunger__feed` story (module
  controller, pure-ts top-level watcher, native Zig hook),
  `engine__tick`, `labelle.FrameArray` pinned flat. CI additionally
  runs THE #613 acceptance negatively: a scratch copy with `h.level`
  typo'd to `h.levl` must FAIL generate with tsc's TS2551 relayed
  verbatim, emit nothing (`noEmitOnError`), and reuse the warm tool
  cache. Recipe + assertions: `.github/workflows/ci.yml` →
  `ts-example`; timeline:
  `examples/ts-game/scripts/20_hunger_controller.ts`.

- **`examples/csharp-game/`** — the CoreCLR-hosted example
  (labelle-engine#743) and a **fully-C# game**: the same hunger sawtooth
  with ALL logic in `scripts/*.cs` (`Script` classes + `Game.Register`),
  including a pure-C# event watcher (`FeedWatcher.cs`, the mirror of
  ruby-game's `scripts/feed_watcher.rb`) in place of the Zig game-root hook
  the rust/crystal examples use. The C# transcript diffs token-for-token
  against the others (`CS_*`). The assembly is not linked in — the plugin's
  declared `dotnet publish` step compiles `scripts/` (staged over the plugin
  package's `native-csharp/src/game/`) into `labelle_csharp_scripts.dll`
  beside the binary, and `src/csharp/vm.zig` loads it at runtime through
  hostfxr, binding the contract via `[LibraryImport]` against the host. The
  ONLY non-C# files are `project.labelle`, `scenes/main.jsonc`, and the
  component schemas `components/*.zig` — C# has no component-schema
  authoring path yet (the contract has no registration call; no
  declare-csharp extractor exists), so those stay Zig as the single
  remaining non-C# piece + a declare-csharp follow-up. Documentation-first:
  no `csharp-example` CI job YET (the assembler csharp splice is a
  follow-up) — the plugin side is proven by `zig build test`'s csharp suite
  driving the managed assembly through the real hostfxr path against the
  mock host. Timeline: `examples/csharp-game/scripts/Game.cs`.
