// scripts/Spawner.cs — the plain-script tier (C# twin of rust-game's
// spawner.rs): seeds the world in Init and commands a feeding over the
// engine bus on tick 2. State lives in the class's fields — the family's
// isolation is the type system itself (two scripts are two objects).
//
// Each observable milestone logs one CS_<TOKEN> line so CI can
// `grep -oE '(CS|ZIG)_[A-Z0-9_.]+'` and diff the ordered sequence.

public sealed class Spawner : Script
{
    private EntityId _worker;
    private uint _tick;
    private bool _engineTickSeen;

    public override void Init()
    {
        // The worker the HungerSystem manages. 0.875 (7/8, exact in binary
        // fp at every width en route) seeds the decay chain; the component's
        // declared default is 1.0, so the read-back chain starting at 0.875
        // proves THIS write traveled through the real ECS.
        _worker = Labelle.CreateEntity();
        Labelle.SetComponent(_worker, "Hunger", "{\"level\":0.875,\"starving\":false}");
        Labelle.SetComponent(_worker, "Worker", "{}");

        // Builtin-event consumption: an ENGINE event that fires every frame
        // in any game shape — proving the engine's own bus reaches C#
        // handlers through the tap.
        Labelle.Subscribe("engine__tick");

        // Ids are ulong END TO END in C# — no bitcast (lua/ruby) or BigInt
        // (typescript) caveat; the true unsigned id prints.
        Labelle.Log($"CS_INIT id={_worker.Value}");
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
        // Command-as-event, CROSS-SCRIPT: this plain script commands the
        // HungerSystem (which subscribed in its Init) to feed the worker.
        // The id and the exact f32 0.5 amount round-trip
        // events/hunger__feed.zig on the real engine bus; the handler sees
        // them on the next tick's inbox.
        if (_tick == 2)
        {
            var payload = $"{{\"entity\":{_worker.Value},\"amount\":0.5}}";
            Labelle.Log(Labelle.Emit("hunger__feed", payload) ? "CS_FEED_SENT" : "CS_FEED_EMIT_FAIL");
        }
    }

    public override void Deinit() => Labelle.Log("CS_DEINIT");
}
