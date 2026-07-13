// The game event the spawner emits (scripts/Spawner.cs, tick 2) and both the
// HungerSystem and FeedWatcher subscribe to — now DECLARED in C#
// (labelle-scripting#27): the `[LabelleEvent]` record's public fields are the
// event's schema, extracted at `labelle generate` by labelle-declare-csharp and
// codegen'd into the game's event union (scripting_events.zig) exactly like the
// former events/hunger__feed.zig. The C# twin of crystal's
// `Labelle.event "hunger__feed"`.
//
// `entity` (u64) carries the fed worker's id and `amount` (f32) the feed size;
// the HungerSystem's OnEvent reads both by name from the JSON payload and the
// values round-trip the real engine bus bit-exact (CS_FED_LEVEL_0.875 +
// CS_WATCHER_SAW_0.5 in the transcript). No `using` — the declare surface is
// global.
[LabelleEvent]
record hunger__feed
{
    public ulong entity = 0;
    public double amount = 0.5;
}
