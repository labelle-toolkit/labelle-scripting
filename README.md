# labelle-scripting

Script [labelle](https://github.com/labelle-toolkit) games in **Lua, TypeScript, Ruby, Rust, Crystal, Go, or C#** — one plugin, one contract.

```zig
// project.labelle
.plugins = .{
    .{ .name = "scripting", .repo = "github.com/labelle-toolkit/labelle-scripting",
       .version = "…", .params = .{ .language = "lua" } },
},
```

Drop scripts in your language's convention dir (`lua/`, `ruby/`, …) and go. One language per project (validated at `labelle generate`); unchosen languages cost nothing — never fetched (lua, a lazy dependency) or never compiled (ruby, an in-repo vendor snapshot).

Every language binds the engine's **Script Runtime Contract** (`labelle-engine/contract/labelle_script.h`, `LABELLE_CONTRACT_VERSION 1`): entities, components-by-name (JSON), events (subscribe + poll-drain), queries, prefabs, input, time. Both integration families — embedded-VM (lua, ruby/mruby, typescript/QuickJS, csharp/CoreCLR) and native-compiled (rust, crystal, go) — consume the identical surface, proven end to end by the [POC](https://github.com/labelle-toolkit/labelle-engine/pull/734).

| sub-module | status |
|---|---|
| `lua` (Lua 5.4) | ✅ bootstrap done (#738) — vendored Lua 5.4.8, contract-bound, tested against a mock host |
| `ruby` (mruby 3.4) | ✅ done (labelle-engine#742) — vendored mruby, controllers + Component.ref + FrameArray, tested against the same mock host |
| `typescript` (QuickJS) | planned |
| `rust` / `crystal` | planned (needs assembler build hooks) |
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

Design: `RFC-LANGUAGE-PLUGINS.md` (labelle-engine#730) · epic: labelle-engine#237
