# labelle-scripting

Script [labelle](https://github.com/labelle-toolkit) games in **Lua, TypeScript, Ruby, Rust, Crystal, Go, or C#** — one plugin, one contract.

```zig
// project.labelle
.plugins = .{
    .{ .name = "scripting", .repo = "github.com/labelle-toolkit/labelle-scripting",
       .version = "…", .language = "lua" },
},
```

Drop scripts in your language's convention dir (`lua/`, `ruby/`, …) and go. One language per project (validated at `labelle generate`); unchosen languages are never even fetched (`b.lazyDependency`).

Every language binds the engine's **Script Runtime Contract** (`labelle-engine/contract/labelle_script.h`, `LABELLE_CONTRACT_VERSION 1`): entities, components-by-name (JSON), events (subscribe + poll-drain), queries, prefabs, input, time. Both integration families — embedded-VM (lua, ruby/mruby, typescript/QuickJS, csharp/CoreCLR) and native-compiled (rust, crystal, go) — consume the identical surface, proven end to end by the [POC](https://github.com/labelle-toolkit/labelle-engine/pull/734).

| sub-module | status |
|---|---|
| `lua` (Lua 5.4) | 🚧 bootstrap (#738) |
| `typescript` (QuickJS) | planned |
| `rust` / `crystal` | planned (needs assembler build hooks) |
| `ruby` (mruby) | planned |
| `go` (c-archive) | planned |
| `csharp` (CoreCLR) | planned — last |

Design: `RFC-LANGUAGE-PLUGINS.md` (labelle-engine#730) · epic: labelle-engine#237
