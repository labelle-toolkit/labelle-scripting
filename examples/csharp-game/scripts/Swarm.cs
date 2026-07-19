// scripts/Swarm.cs — the BULK-ACCESS example behavior (contract v1.3,
// labelle-scripting#44): a 3-boid swarm integrated through the typed batch
// iterator, `Labelle.Batch<BoidView, BoidVelView>((ref b, ref v) => …)` —
// the RFC's headline shape. ONE BatchGet + ONE BatchSet per tick move the
// whole swarm across the FFI boundary, and the delegate runs over `ref`
// views reinterpreted IN PLACE on the stream buffer (zero copy,
// write-through, JIT-inlined — near flat-loop speed), where per-entity
// Get/Set would cross 4× per boid.
//
// The view structs mirror the DECLARED components (components/Boid.cs /
// BoidVel.cs) field for field — the struct size IS the declared stride,
// cross-checked against the real host stream every tick, so a drift
// refuses loudly instead of mis-mapping.
//
// The transcript pin: all values are exact in binary floating point
// (x₀ ∈ {1,2,3}, vx = 0.5), so after 5 ticks Σx = 6 + 3×2.5 = 13.5 exactly
// and tick 5 logs `CS_BATCH_OK_3_13.5` — count and checksum prove three
// entities round-tripped the stream five times through the REAL engine
// host (an engine < 2.6.0 would throw here: there is no batch fallback).
// The SUM is the pin on purpose: the engine's query order is not creation
// order, so any single entity's value would be order-dependent.

using System.Globalization;

// CS0649 is a false positive: the fields are ASSIGNED through the stream
// reinterpret (write-through refs over the batch buffer), never by name.
#pragma warning disable CS0649
internal struct BoidView : IBatchComponent
{
    public float X, Y;
    public static string Name => "Boid";
}

internal struct BoidVelView : IBatchComponent
{
    public float Vx, Vy;
    public static string Name => "BoidVel";
}
#pragma warning restore CS0649

public sealed class Swarm : Script
{
    private uint _tick;

    public override void Init()
    {
        for (var i = 0; i < 3; i++)
        {
            var e = Labelle.CreateEntity();
            Labelle.SetComponent(e, "Boid", $"{{\"x\":{i + 1},\"y\":0}}");
            Labelle.SetComponent(e, "BoidVel", "{\"vx\":0.5,\"vy\":0}");
        }
    }

    public override void Update(float dt)
    {
        _tick++;
        var sumX = 0.0f;
        var n = Labelle.Batch<BoidView, BoidVelView>((ref BoidView b, ref BoidVelView v) =>
        {
            b.X += v.Vx;
            b.Y += v.Vy;
            sumX += b.X;
        });
        if (_tick == 5)
            Labelle.Log($"CS_BATCH_OK_{n}_{sumX.ToString(CultureInfo.InvariantCulture)}");
    }
}
