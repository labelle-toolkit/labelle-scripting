// scripts/Game.cs — the game's registration entry point (labelle-engine
// #743, the CoreCLR-hosted family). At `labelle generate` the assembler
// compiles this game's `scripts/*.cs` into the scripting plugin's managed
// assembly (`labelle_csharp_scripts.dll`, via `dotnet publish` — the
// plugin's declared `.language_builds` step) and the game binary loads it at
// RUNTIME through hostfxr; the `labelle_*` contract symbols the assembly
// calls resolve against the host's exports (Labelle.cs's DllImportResolver).
// No source is embedded and no VM interprets text — C#'s "VM" is the
// embedded CoreCLR runtime, and scripts are compiled types.
//
// The game mirrors examples/rust-game and examples/crystal-game's hunger
// sawtooth so the cross-language story is visible token-for-token — but this
// example is FULLY C#: everything except the config (project.labelle), the
// scene (scenes/main.jsonc) and the component schemas (components/*.zig — see
// below) lives in scripts/*.cs. Where rust/crystal use a native Zig hook
// (hooks/feed_watcher.zig) as the second event subscriber, this game uses a
// pure-C# watcher SCRIPT (scripts/FeedWatcher.cs) — the C# mirror of
// ruby-game's scripts/feed_watcher.rb.
//
// Components stay Zig (components/hunger.zig + worker.zig): the Script Runtime
// Contract has no component-registration call and there is no declare-csharp
// extractor yet (only lua's tools/declare and tools/declare-ruby exist), so
// C# cannot author a component SCHEMA — that is the single remaining non-C#
// piece and a declare-csharp follow-up. C# still reads/writes those components
// by name over the contract at runtime. (Same story for the custom event: its
// only Zig artifact was the typed struct the removed Zig hook consumed;
// the C# scripts use "hunger__feed" purely by name + JSON.)
//
// Registration order is hook order: the spawner registers FIRST (its Init
// seeds the world before the system's, its Update runs first each tick),
// then the hunger system, then the watcher (unnumbered — registers last,
// like ruby-game's feed_watcher.rb); Deinit runs in REVERSE order.
//
// Frame-by-frame (LABELLE_NULL_FRAMES=5; per frame the plugin Controller
// runs: inbox dispatch (OnEvents) → Updates, both in registration order):
//
//   setup   CS_INIT               (spawner Init: worker seeded at 0.875)
//           CS_CTRL_READY         hunger system Init (after the spawner's)
//   tick 1  CS_LEVEL_0.625        0.875 - 0.25 decay, written back
//   tick 2  CS_FEED_SENT          (spawner Update: emits hunger__feed)
//           CS_LEVEL_0.375        0.625 - 0.25 — tick 1's write PERSISTED
//   tick 3  CS_ENGINE_TICK_SEEN   (spawner's builtin sub, same inbox)
//           CS_FED_LEVEL_0.875    hunger system inbox: 0.375 + 0.5 re-read
//                                  AFTER the write
//           CS_WATCHER_SAW_0.5    the pure-C# watcher SCRIPT, same inbox —
//                                  a drain-boundary later than a native hook
//           CS_LEVEL_0.625        0.875 - 0.25 — decay resumes on the fed
//   tick 4  CS_LEVEL_0.375
//   tick 5  CS_LEVEL_0.125
//           CS_STARVING           0.125 <= 0.25 crossed the threshold
//   deinit  CS_CTRL_DONE          hunger system (reverse registration)
//           CS_DEINIT             spawner
//
// (Script API types — Script, Scripts, EntityId, Labelle — are in the
// global namespace; see the plugin's native-csharp/src/Labelle.cs.)

public static class Game
{
    public static void Register(Scripts scripts)
    {
        scripts.Add("spawner", new Spawner());
        scripts.Add("hunger", new HungerSystem());
        scripts.Add("watcher", new FeedWatcher());
    }
}
