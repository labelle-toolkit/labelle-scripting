// scripts/FeedWatcher.cs — a pure-C# hunger__feed watcher, the C# mirror of
// ruby-game's scripts/feed_watcher.rb. It replaces the Zig game-root hook
// (hooks/feed_watcher.zig) the rust/crystal examples use: everything here is
// C#, so the "second subscriber" is just another Script, not a native hook.
//
// One `Labelle.Emit("hunger__feed", …)` in scripts/Spawner.cs (tick 2) now
// reaches BOTH C# subscribers off the same engine bus, no glue:
//
//   - the HungerSystem's OnEvent (feeds the worker), and
//   - THIS stateless watcher.
//
// The token carries the parsed payload amount (CS_WATCHER_SAW_0.5 — f32 0.5
// is exact in binary floating point), proving the JSON payload crossed intact,
// not just that a handler fired.
//
// Unlike the Zig hook (which ran at the SAME frame's dispatchEvents), a script
// subscriber receives the event on the NEXT tick's inbox dispatch — so
// CS_WATCHER_SAW_0.5 lands on tick 3 alongside the controller's
// CS_FED_LEVEL_*, one drain-boundary later than the native hook would have.
//
// (Script API types — Script, Labelle — are in the global namespace; see the
// plugin's native-csharp/src/Labelle.cs.)

using System.Globalization;

public sealed class FeedWatcher : Script
{
    public override void Init() => Labelle.Subscribe("hunger__feed");

    public override void OnEvent(string name, string payload)
    {
        if (name != "hunger__feed") return;
        var amount = Json.F32(payload, "\"amount\":", 0f);
        Labelle.Log("CS_WATCHER_SAW_" + amount.ToString(CultureInfo.InvariantCulture));
    }
}
