// The csharp suite's scenario scripts (labelle-engine#743) — the C# twin of
// tests/rust/game and tests/crystal/game: two Script classes exercising the
// whole lifecycle and contract surface, driven by tests/csharp_suite.zig and
// asserted against the mock world (logs, components, events).
//
// Each observable milestone logs one CS_<TOKEN> line the suite greps for.
// State lives in instance fields — the CoreCLR family's isolation is the type
// system itself (two scripts are two objects).

using System.Globalization;

// (Script API types are in the global namespace — see native-csharp/src/Labelle.cs.)

// The plain-script tier: seeds the world and commands a feeding on tick 2.
public sealed class Spawner : Script
{
    private EntityId _worker;
    private uint _tick;
    private bool _engineTickSeen;

    public override void Init()
    {
        _worker = Labelle.CreateEntity();
        // 0.875 (7/8, exact in binary fp) seeds the decay chain; the
        // component's declared default is 1.0, so the read-back chain
        // starting at 0.875 proves THIS write traveled through the ECS.
        Labelle.SetComponent(_worker, "Hunger", "{\"level\":0.875,\"starving\":false}");
        Labelle.SetComponent(_worker, "Worker", "{}");
        Labelle.Subscribe("engine__tick");
        Labelle.Log($"CS_INIT id={_worker}");
    }

    public override void OnEvent(string name, string payload)
    {
        if (name == "engine__tick" && !_engineTickSeen)
        {
            _engineTickSeen = true;
            Labelle.Log("CS_ENGINE_TICK_SEEN");
        }
    }

    public override void Update(float dt)
    {
        _tick++;
        if (_tick == 2)
        {
            var payload = $"{{\"entity\":{_worker.Value},\"amount\":0.5}}";
            Labelle.Log(Labelle.Emit("hunger__feed", payload) ? "CS_FEED_SENT" : "CS_FEED_EMIT_FAIL");
        }
    }

    public override void Deinit() => Labelle.Log("CS_DEINIT");
}

// The system tier: the labelle-engine#742 HungerController pattern — buffer
// reuse at every contract boundary, command-as-event feeding, decay sawtooth.
public sealed class HungerSystem : Script
{
    private const float DecayPerTick = 0.25f; // exact in binary fp
    private const float StarveAt = 0.25f;
    private const float FeedDefault = 0.5f;

    // Reused across ticks — held in fields so the steady state grows nothing.
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
        if (!Json.TryU64(payload, "\"entity\":", out var entityRaw)) return;
        var amount = Json.F32(payload, "\"amount\":", FeedDefault);
        Feed(new EntityId(entityRaw), amount);
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
            Labelle.Log("CS_LEVEL_" + level.ToString(CultureInfo.InvariantCulture));
            if (starving && !_wasStarving)
            {
                _wasStarving = true;
                Labelle.Log("CS_STARVING");
            }
        }
    }

    public override void Deinit() => Labelle.Log("CS_CTRL_DONE");

    private void Feed(EntityId id, float amount)
    {
        var n = Labelle.GetComponentInto(id, "Hunger", ref _comp);
        if (n == 0)
        {
            Labelle.Log("CS_FEED_TARGET_MISSING");
            return;
        }
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

    // Decode the freshly filled component bytes as a string (cold-path parse
    // helper — a production script would parse straight from the span).
    private string Text(int n) => System.Text.Encoding.UTF8.GetString(_comp, 0, n);
}

// Minimal flat-JSON field extraction (contract payloads are small, flat JSON;
// a structured serializer is future work). Mirrors the rust example's byte
// walkers — no float ever touches an entity id (ulong end to end).
internal static class Json
{
    public static bool TryU64(string json, string needle, out ulong value)
    {
        value = 0;
        var i = ValueStart(json, needle);
        if (i < 0) return false;
        if (i < json.Length && json[i] == '"') i++;
        bool any = false;
        while (i < json.Length && json[i] >= '0' && json[i] <= '9')
        {
            value = value * 10 + (ulong)(json[i] - '0');
            any = true;
            i++;
        }
        return any;
    }

    public static float F32(string json, string needle, float fallback)
    {
        var start = ValueStart(json, needle);
        if (start < 0) return fallback;
        var end = start;
        while (end < json.Length && "0123456789+-.eE".IndexOf(json[end]) >= 0) end++;
        return end > start && float.TryParse(json.AsSpan(start, end - start),
            NumberStyles.Float, CultureInfo.InvariantCulture, out var v)
            ? v : fallback;
    }

    private static int ValueStart(string json, string needle)
    {
        var at = json.IndexOf(needle, System.StringComparison.Ordinal);
        if (at < 0) return -1;
        var i = at + needle.Length;
        while (i < json.Length && char.IsWhiteSpace(json[i])) i++;
        return i;
    }
}
