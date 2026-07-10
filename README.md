# labelle-scripting

Script [labelle](https://github.com/labelle-toolkit) games in **Lua, TypeScript, Ruby, Rust, Crystal, Go, or C#** — one plugin, one contract.

```zig
// project.labelle
.plugins = .{
    .{ .name = "scripting", .repo = "github.com/labelle-toolkit/labelle-scripting",
       .version = "…", .params = .{ .language = "lua" } },
},
```

Drop scripts in your language's convention dir (`lua/`, `ruby/`, …) and go. One language per project (validated at `labelle generate`); unchosen languages are never even fetched (`b.lazyDependency`).

Every language binds the engine's **Script Runtime Contract** (`labelle-engine/contract/labelle_script.h`, `LABELLE_CONTRACT_VERSION 1`): entities, components-by-name (JSON), events (subscribe + poll-drain), queries, prefabs, input, time. Both integration families — embedded-VM (lua, ruby/mruby, typescript/QuickJS, csharp/CoreCLR) and native-compiled (rust, crystal, go) — consume the identical surface, proven end to end by the [POC](https://github.com/labelle-toolkit/labelle-engine/pull/734).

| sub-module | status |
|---|---|
| `lua` (Lua 5.4) | ✅ bootstrap done (#738) — vendored Lua 5.4.8, contract-bound, tested against a mock host |
| `typescript` (QuickJS) | planned |
| `rust` / `crystal` | planned (needs assembler build hooks) |
| `ruby` (mruby) | planned |
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

Design: `RFC-LANGUAGE-PLUGINS.md` (labelle-engine#730) · epic: labelle-engine#237
