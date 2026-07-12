// scripts/HungerSystem.cs — the labelle-engine#742 HungerController pattern,
// ported to the CoreCLR-hosted family (C# twin of rust-game's hunger.rs):
//
//   - a plain class deriving Script, ALL state in its fields — no VM
//     registry magic,
//   - the buffer-reuse idiom at every contract boundary: caller-owned
//     byte[] buffers held in fields, refilled per tick by QueryInto /
//     GetComponentInto (grown at most once via the contract's required-size
//     legs) — the managed GC's high-water-mark steady state,
//   - command-as-event feeding (`hunger__feed`, events/hunger__feed.zig)
//     subscribed in Init — emitted by scripts/Spawner.cs on tick 2, so the
//     cross-script round-trip over the engine bus is part of the transcript,
//   - a NATIVE game-root Zig hook (hooks/feed_watcher.zig) consumes the SAME
//     hunger__feed from the same bus — the two-layer interop.
//
// `Hunger` is a real engine component (components/hunger.zig) — C# has no
// declare mode, so every call addresses it by name over the contract at
// runtime. Timeline: scripts/Game.cs's header.

using System.Globalization;

public sealed class HungerSystem : Script
{
    private const float DecayPerTick = 0.25f; // exact in binary fp
    private const float StarveAt = 0.25f;
    private const float FeedDefault = 0.5f;

    private readonly List<EntityId> _ids = new();
    private byte[] _scratch = System.Array.Empty<byte>();
    private byte[] _comp = new byte[64];
    private uint _tick;
    private bool _wasStarving;

    public override void Init()
    {
        Labelle.Subscribe("hunger__feed");
        Labelle.Log("CS_CTRL_READY");
    }

    public override void OnEvent(string name, string payload)
    {
        if (name != "hunger__feed") return;
        // Guard the payload: a malformed feed without an entity has no
        // target (mirrors the rust handler's `if ev[:entity]`).
        if (!Json.TryU64(payload, "\"entity\":", out var entity)) return;
        var amount = Json.F32(payload, "\"amount\":", FeedDefault);
        Feed(new EntityId(entity), amount);
    }

    public override void Update(float dt)
    {
        _tick++;
        if (!Labelle.QueryInto("[\"Hunger\",\"Worker\"]", _ids, ref _scratch)) return;
        foreach (var id in _ids)
        {
            var n = Labelle.GetComponentInto(id, "Hunger", ref _comp);
            if (n == 0) continue;
            var level = Json.F32(Text(n), "\"level\":", 0f) - DecayPerTick;
            var starving = level <= StarveAt;
            WriteHunger(id, level, starving);
            // The token carries the WRITTEN value — each tick's number is
            // only reachable through the PREVIOUS tick's persisted write, so
            // the sequence pins ECS persistence transitively.
            Labelle.Log("CS_LEVEL_" + level.ToString(CultureInfo.InvariantCulture));
            if (starving && !_wasStarving)
            {
                _wasStarving = true;
                Labelle.Log("CS_STARVING");
            }
        }
    }

    public override void Deinit() => Labelle.Log("CS_CTRL_DONE");

    // The ruby controller's `feed` method, verbatim story.
    private void Feed(EntityId id, float amount)
    {
        var n = Labelle.GetComponentInto(id, "Hunger", ref _comp);
        if (n == 0) { Labelle.Log("CS_FEED_TARGET_MISSING"); return; }
        var level = Json.F32(Text(n), "\"level\":", 0f) + amount;
        WriteHunger(id, level, level <= StarveAt);
        // Re-read AFTER the write: the token carries what PERSISTED.
        n = Labelle.GetComponentInto(id, "Hunger", ref _comp);
        if (n > 0)
            Labelle.Log("CS_FED_LEVEL_" + Json.F32(Text(n), "\"level\":", 0f).ToString(CultureInfo.InvariantCulture));
    }

    private void WriteHunger(EntityId id, float level, bool starving)
    {
        var json = "{\"level\":" + level.ToString(CultureInfo.InvariantCulture) +
                   ",\"starving\":" + (starving ? "true" : "false") + "}";
        Labelle.SetComponent(id, "Hunger", json);
    }

    private string Text(int n) => System.Text.Encoding.UTF8.GetString(_comp, 0, n);
}
