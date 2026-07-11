# labelle-scripting

Script [labelle](https://github.com/labelle-toolkit) games in **Lua, TypeScript, Ruby, Rust, Crystal, Go, or C#** — one plugin, one contract.

```zig
// project.labelle
.plugins = .{
    .{ .name = "scripting", .repo = "github.com/labelle-toolkit/labelle-scripting",
       .version = "…", .params = .{ .language = "lua" } },
},
```

Drop scripts in your language's convention dir (`lua/`, `ruby/`, `ts/`, …) and go. One language per project (validated at `labelle generate`); unchosen languages cost nothing — never fetched (lua and quickjs, lazy dependencies) or never compiled (ruby, an in-repo vendor snapshot).

Every language binds the engine's **Script Runtime Contract** (`labelle-engine/contract/labelle_script.h`, `LABELLE_CONTRACT_VERSION 1`): entities, components-by-name (JSON), events (subscribe + poll-drain), queries, prefabs, input, time. Both integration families — embedded-VM (lua, ruby/mruby, typescript/QuickJS, csharp/CoreCLR) and native-compiled (rust, crystal, go) — consume the identical surface, proven end to end by the [POC](https://github.com/labelle-toolkit/labelle-engine/pull/734).

| sub-module | status |
|---|---|
| `lua` (Lua 5.4) | ✅ bootstrap done (#738) + per-frame allocation utilities (#2) — vendored Lua 5.4.8, contract-bound, tested against a mock host |
| `ruby` (mruby 3.4) | ✅ done (labelle-engine#742) — vendored mruby, controllers + Component.ref + FrameArray, tested against the same mock host |
| `typescript` (QuickJS) | ✅ done (labelle-engine#745) — quickjs-ng 0.15, ES-module scripts, BigInt ids, typed via contract/labelle.d.ts, tested against the same mock host (plain JS at runtime; the TS→JS transpile hook is assembler#586) |
| `rust` (staticlib) | ✅ done (labelle-engine#741) — first native-compiled sub-module: game `rust/` sources cargo-built into the shipped crate (`native/`), `Script` trait + safe wrappers, panics caught at every FFI entry, tested against the same mock host (end-to-end game wiring needs the assembler's native-language splice — the #741 follow-up) |
| `crystal` (localized object) | ✅ done (labelle-engine#741) — second native-compiled sub-module on rust's skeleton: game `crystal/` sources built by `crystal build --cross-compile` + a main-localization pass into a linkable object, `Labelle::Script` class + safe wrappers, every raise rescued at every FFI entry, GC collections enabled (host-thread runtime boot), tested against the same mock host (same assembler-splice follow-up as rust) |
| `go` (c-archive) | planned |
| `csharp` (CoreCLR) | planned — last |

## Using the lua sub-module

Zig side — register sources, wire the plugin controller (the assembler
generates exactly this; until script-dir embedding lands, `registerScript`
is the seam you call yourself):

```zig
const scripting = @import("labelle_scripting");

// once at boot, before setup — name = chunkname in error tracebacks
scripting.registerScript("player", @embedFile("lua/player.lua"));

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
`Labelle::FrameArray` (below); typescript will lean on typed arrays /
reused objects over the same contract when it lands.

## Using the ruby sub-module

Build with `-Dlanguage=ruby`. The Zig side is identical to lua — same
`registerScript`/`Controller` seam, same contract, same mock-tested
semantics — only the sources are `.rb`:

```zig
scripting.registerScript("hunger", @embedFile("ruby/10_hunger.rb"));
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
`e.set("Hunger", h)` also work). Forward compat: declare-mode-generated
component classes will arrive as auto-created refs with this surface.

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

## Using the typescript sub-module

Build with `-Dlanguage=typescript` (embeds [quickjs-ng](https://github.com/quickjs-ng/quickjs)
0.15, a pinned lazy dependency compiled only when selected). The Zig side
is identical to lua/ruby — same `registerScript`/`Controller` seam, same
contract, same mock-tested semantics — only the sources are JavaScript:

```zig
scripting.registerScript("player", @embedFile("ts/player.js"));
```

Scripts are **plain JS at runtime** — the TS→JS transpile arrives with
the assembler build hook (labelle-assembler#586). What makes this the
*typescript* sub-module today is the authoring surface:
`contract/labelle.d.ts` hand-declares types for the whole script API, so
you get typed autocomplete and checking now:

- **.js scripts**: put `// @ts-check` at the top and add a
  `jsconfig.json` whose `"include"` lists your scripts plus
  `labelle.d.ts` (copy it or point at the resolved package's
  `contract/` dir) — your editor checks every call against the real API.
- **.ts scripts**: check with `tsc --noEmit` the same way, and (until
  assembler#586 lands) run the emitted `.js` through `registerScript`.

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
`rust/` dir is compiled by cargo into the crate this plugin ships
(`native/` — Cargo manifest, the `labelle` module, the entry-point glue)
as its `game` module, producing `liblabelle_rust_scripts.a`, which links
into the game binary. The contract header IS the binding (the POC's
finding): the crate declares the `labelle_*` symbols `extern "C"` and
they resolve against the host's exports in the same binary — zero
bindings layer, zero indirection. The plugin's Zig side shrinks to a
thin dispatcher onto the glue's `labelle_rs_*` entry points
(`src/rust/vm.zig`), driven by the same Controller as every VM language.

Your `rust/mod.rs` implements one convention entry point; scripts are
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
native-language splice — the #741 follow-up: it stages your `rust/` over
the staged package's `native/src/game/`, passes `-Dlanguage=rust`, and
runs the build step declared in this repo's `plugin.labelle`
(`.language_builds` — cargo → staticlib → `addObjectFile`, desktop-first).
Until that assembler release, the sub-module is fully usable against the
mock host and via hand-wiring (link the staticlib yourself, as
build.zig's own test wiring demonstrates). Needs a rust toolchain
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
`crystal/` dir is compiled by `crystal build --cross-compile` together
with the sources this plugin ships (`native-crystal/` — the `Labelle`
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

Your `crystal/game.cr` implements one convention entry point; scripts
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
rides the assembler's native-language splice — the same #741 follow-up
as rust: it stages your `crystal/` over the staged package's
`native-crystal/src/game/`, passes `-Dlanguage=crystal`, and runs the
two steps declared in this repo's `plugin.labelle` (`.language_builds`
— crystal build → `ld -r`/objcopy → `addObjectFile`, desktop-first).
Until that assembler release, the sub-module is fully usable against
the mock host and via hand-wiring (build and localize the object
yourself, as build.zig's own test wiring demonstrates). Needs a
crystal toolchain (≥ 1.16 — `Crystal.init_runtime`) wherever the game
builds.

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
  `ruby/` scripts drive the real engine end-to-end through the Script
  Runtime Contract: the `#742` HungerController pattern
  (`Component.ref` + `get(…, into:)` + `set`), a cross-script
  `hunger__feed` command-event, an `engine__tick` builtin subscription,
  `FrameArray` in the hot loop, and plain top-level hooks. It also
  demonstrates the cross-layer interop: a game-root Zig hook
  (`hooks/feed_watcher.zig`) consumes the SAME `hunger__feed` from the
  same engine bus, natively — scripts for iteration speed, `hooks/` as
  the native escape, no glue. Pins: the scripting plugin `local:../..`
  (THIS checkout — every CI run exercises the current tree),
  core/engine/gfx registry releases, a sibling `labelle-null` clone
  (its bind touchpoint is unreleased), and a pinned labelle-assembler
  release binary. CI generates, builds, runs `LABELLE_NULL_FRAMES=5`
  and diffs the ordered `RUBY_*`/`ZIG_*` transcript — ruby's permanent
  regression net (labelle-scripting#10). Recipe + assertions:
  `.github/workflows/ci.yml` → `ruby-example`; timeline:
  `examples/ruby-game/ruby/hunger_controller.rb`.
