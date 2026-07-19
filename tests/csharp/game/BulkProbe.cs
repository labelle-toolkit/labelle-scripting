// Bulk-component-access scenario script (contract v1.3, labelle-scripting#44)
// — the C# mirror of the ruby suite's "bulk v1.3" / "bulk stage 2" coverage
// (and tests/rust/game/bulk.rs / tests/crystal/game/bulk.cr's twin), driven
// against the mock world's packed schema table (Stats / BatchPos / BatchVel;
// "Plain" plays the non-packable component).
//
// Unlike the rust/crystal suites there is no scenario selector: this script
// registers THIRD (after spawner + hunger, whose entity 1 it never touches)
// and runs its whole edge matrix in Init on its own entities, logging one
// CS_BULK_* token per verified milestone; Update exercises the typed
// iterator's steady state on three dedicated entities
// (tests/csharp_suite.zig asserts the tokens and the world).

using System.Globalization;

// The typed packed views (IPackedView — the mechanical field walk).
internal sealed class StatsView : IPackedView
{
    public float Power;
    public long Score;
    public bool Alive;
    public ulong Seed;

    public static string ComponentName => "Stats";

    public bool SetField(ReadOnlySpan<byte> name, in Scalar v)
    {
        // The Try* accessors carry the documented coercion matrix: the
        // JSON fallback's int-class whole numbers land in float fields,
        // exact floats land in int fields, and the 64-bit bitcast pair
        // rides TryU64/TryI64 losslessly.
        if (name.SequenceEqual("power"u8)) { if (v.TryF32(out var f)) Power = f; return true; }
        if (name.SequenceEqual("score"u8)) { if (v.TryI64(out var i)) Score = i; return true; }
        if (name.SequenceEqual("alive"u8)) { if (v.TryBool(out var b)) Alive = b; return true; }
        if (name.SequenceEqual("seed"u8)) { if (v.TryU64(out var u)) Seed = u; return true; }
        return false;
    }

    public void EachField(IFieldSink sink)
    {
        sink.Field("power", Scalar.F32(Power));
        sink.Field("score", Scalar.I64(Score));
        sink.Field("alive", Scalar.Bool(Alive));
        sink.Field("seed", Scalar.U64(Seed));
    }
}

internal sealed class PlainView : IPackedView
{
    public float A;

    public static string ComponentName => "Plain";

    public bool SetField(ReadOnlySpan<byte> name, in Scalar v)
    {
        if (name.SequenceEqual("a"u8)) { if (v.TryF32(out var f)) A = f; return true; }
        return false;
    }

    public void EachField(IFieldSink sink) => sink.Field("a", Scalar.F32(A));
}

// The typed batch views (IBatchComponent — float-only sequential structs;
// the struct size IS the declared stride). CS0649 is a false positive
// here: the fields are ASSIGNED through the stream reinterpret
// (Unsafe.As over the batch buffer), never by name.
#pragma warning disable CS0649
internal struct BatchPos : IBatchComponent
{
    public float X, Y;
    public static string Name => "BatchPos";
}

internal struct BatchVel : IBatchComponent
{
    public float Vx, Vy;
    public static string Name => "BatchVel";
}

/// A view whose declared stride DISAGREES with the host stream: "Plain"
/// has no packed schema, so it contributes ZERO stream floats (the mock's
/// stand-in for a non-scalar component) while this struct declares one —
/// the cross-check must refuse, never mis-map.
internal struct PlainStream : IBatchComponent
{
    public float A;
    public static string Name => "Plain";
}

/// A bool-carrying view — the float-only enforcement's test double: a
/// 1-byte CLR bool overlaid on a 4-byte float slot would read garbage,
/// so ViewInfo refuses the TYPE before any host call.
internal struct BadBoolView : IBatchComponent
{
    public float X;
    public bool Flag;
    public static string Name => "BatchPos";
}
#pragma warning restore CS0649

public sealed class BulkProbe : Script
{
    private byte[] _scratch = System.Array.Empty<byte>();
    private byte[] _comp = new byte[64];
    private float[] _raw = System.Array.Empty<float>();
    private uint _tick;

    private static string F(float v) => v.ToString(CultureInfo.InvariantCulture);

    private float ReadX(EntityId id)
    {
        var n = Labelle.GetComponentInto(id, "BatchPos", ref _comp);
        return n == 0 ? float.NaN : Json.F32(System.Text.Encoding.UTF8.GetString(_comp, 0, n), "\"x\":", float.NaN);
    }

    public override void Init()
    {
        // Empty query FIRST (no BatchPos entities yet): 0, delegate untouched.
        var none = Labelle.Batch<BatchPos, BatchVel>((ref BatchPos _, ref BatchVel _) =>
            Labelle.Log("CS_BULK_EMPTY_RAN"));
        Labelle.Log($"CS_BULK_EMPTY_{none}");

        // Packed round-trip: every scalar kind (f32/i64/bool/u64) through
        // the binary codec (the mock stores SCHEMA-order JSON on this
        // path — the Zig side asserts the key order as the path proof).
        var e = Labelle.CreateEntity();
        var s = new StatsView { Power = 1.5f, Score = -42, Alive = true, Seed = 123 };
        if (!Labelle.SetFrom(e, s)) { Labelle.Log("CS_BULK_PACKED_SET_FAIL"); return; }
        var s2 = new StatsView();
        if (!Labelle.GetInto(e, s2, ref _scratch)) { Labelle.Log("CS_BULK_PACKED_GET_FAIL"); return; }
        Labelle.Log($"CS_BULK_PACKED_{F(s2.Power)}_{s2.Score}_{s2.Alive}_{s2.Seed}");

        // The schema-less component round-trips through JSON (set_packed
        // -1 / get_packed 0xFF), invisibly to the script.
        var p = new PlainView { A = 2.5f };
        if (!Labelle.SetFrom(e, p)) { Labelle.Log("CS_BULK_PLAIN_SET_FAIL"); return; }
        var p2 = new PlainView();
        if (!Labelle.GetInto(e, p2, ref _scratch)) { Labelle.Log("CS_BULK_PLAIN_GET_FAIL"); return; }
        Labelle.Log($"CS_BULK_PLAIN_{F(p2.A)}");

        // JSON-fallback coercion (round 1): a whole-number float is
        // spelled `2` in JSON — an int-class token — and must still
        // land in the f32 view field on the fallback path.
        Labelle.SetComponent(e, "Plain", "{\"a\":2}");
        var p3 = new PlainView();
        if (Labelle.GetInto(e, p3, ref _scratch)) Labelle.Log($"CS_BULK_PLAIN_INT_{F(p3.A)}");
        // And our OWN JSON fallback spells whole floats the same way —
        // the SetFrom -> GetInto round trip must survive it.
        var whole = new PlainView { A = 3.0f };
        var p4 = new PlainView();
        if (Labelle.SetFrom(e, whole) && Labelle.GetInto(e, p4, ref _scratch))
            Labelle.Log($"CS_BULK_PLAIN_WHOLE_{F(p4.A)}");

        // A bit-63 u64 rides tag 3 bit-exact (C# has a real ulong).
        var e2 = Labelle.CreateEntity();
        var big = new StatsView { Seed = 0x8000000000000001UL };
        var b2 = new StatsView();
        if (Labelle.SetFrom(e2, big) && Labelle.GetInto(e2, b2, ref _scratch) && b2.Seed == 0x8000000000000001UL)
            Labelle.Log("CS_BULK_U64_OK");

        // Non-finite policy: NaN refuses up front — nothing stored
        // (parity with this family's hand-written-JSON route).
        var e3 = Labelle.CreateEntity();
        if (!Labelle.SetFrom(e3, new StatsView { Power = float.NaN }))
            Labelle.Log("CS_BULK_NAN_REFUSED");
        // An absent component answers false through BOTH routes.
        if (!Labelle.GetInto(e3, new StatsView(), ref _scratch))
            Labelle.Log("CS_BULK_ABSENT_OK");

        // Int-carrying components refuse LOUDLY on both batch directions.
        try { Labelle.BatchGet("[\"BatchPos\",\"Stats\"]", ref _raw, out _); }
        catch (System.ArgumentException) { Labelle.Log("CS_BULK_GET_INT_REFUSED"); }
        try { Labelle.BatchSet("[\"Stats\"]", new float[4], 4); }
        catch (System.ArgumentException) { Labelle.Log("CS_BULK_SET_INT_REFUSED"); }

        // Non-finite refusal at the BINDING (#45): a NaN/Inf stream
        // element refuses BEFORE any host write. A finite float overflow
        // (MAX doubled → Infinity) is the "1e100 narrows to inf" smuggle
        // in a float-native binding, and lands on the same refusal.
        try { Labelle.BatchSet("[\"BatchPos\"]", new[] { 1.0f, float.NaN }, 2); }
        catch (System.ArgumentException) { Labelle.Log("CS_BULK_SET_NAN_REFUSED"); }
        try { Labelle.BatchSet("[\"BatchPos\"]", new[] { 1.0f, float.MaxValue * 2.0f }, 2); }
        catch (System.ArgumentException) { Labelle.Log("CS_BULK_SET_OVERFLOW_REFUSED"); }

        // floatCount is bounds-checked against the array BEFORE any read
        // (gemini #53): an oversized or negative count throws
        // ArgumentOutOfRangeException instead of indexing past the buffer.
        try { Labelle.BatchSet("[\"BatchPos\"]", new float[2], 5); }
        catch (System.ArgumentOutOfRangeException) { Labelle.Log("CS_BULK_SET_COUNT_OVER_REFUSED"); }
        try { Labelle.BatchSet("[\"BatchPos\"]", new float[2], -1); }
        catch (System.ArgumentOutOfRangeException) { Labelle.Log("CS_BULK_SET_COUNT_NEG_REFUSED"); }

        // ── exit-semantics matrix on THROWAWAY entities ────────────────
        var t1 = Labelle.CreateEntity();
        var t2 = Labelle.CreateEntity();
        var t3 = Labelle.CreateEntity();
        var temps = new[] { t1, t2, t3 };
        for (var i = 0; i < 3; i++)
        {
            Labelle.SetComponent(temps[i], "BatchPos", $"{{\"x\":{i + 1},\"y\":0}}");
            Labelle.SetComponent(temps[i], "BatchVel", "{\"vx\":0,\"vy\":0}");
        }

        // EARLY EXIT COMMITS: stop after the first row — its write
        // (write-through ref into the stream buffer) flushes through the
        // one BatchSet; not-yet-visited rows round-trip unchanged.
        var nw = Labelle.BatchWhile<BatchPos, BatchVel>((ref BatchPos bp, ref BatchVel _) =>
        {
            bp.X += 10.0f;
            return false;
        });
        if (nw == 3 && ReadX(t1) == 11.0f && ReadX(t2) == 2.0f && ReadX(t3) == 3.0f)
            Labelle.Log("CS_BULK_WHILE_COMMIT_OK");

        // A THROWING delegate aborts the whole write: BatchSet never
        // runs, the mutation before the throw is not applied.
        try
        {
            Labelle.Batch<BatchPos, BatchVel>((ref BatchPos bp, ref BatchVel _) =>
            {
                bp.X = 999.0f;
                throw new System.InvalidOperationException("boom");
            });
            Labelle.Log("CS_BULK_THROW_SWALLOWED");
        }
        catch (System.InvalidOperationException)
        {
            if (ReadX(t1) == 11.0f) Labelle.Log("CS_BULK_THROW_ABORTED");
        }

        // DUPLICATE COMPONENT NAMES: two copies of the same fields per
        // row would let the unchanged copy overwrite the other's writes
        // — refused before any host call, nothing written.
        try
        {
            Labelle.Batch<BatchPos, BatchPos>((ref BatchPos bp, ref BatchPos _) => bp.X = 555.0f);
            Labelle.Log("CS_BULK_DUP_ACCEPTED");
        }
        catch (System.ArgumentException) { Labelle.Log("CS_BULK_DUP_REFUSED"); }

        // FLOAT-ONLY enforcement: a bool-carrying view type is refused
        // before any host call (the zero-copy overlay would read a
        // 1-byte bool as float garbage).
        try
        {
            Labelle.Batch<BadBoolView>((ref BadBoolView _) => { });
            Labelle.Log("CS_BULK_BOOLVIEW_ACCEPTED");
        }
        catch (BatchRefusedException) { Labelle.Log("CS_BULK_BOOLVIEW_REFUSED"); }

        // NESTED Batch calls alias the shared stream buffer — refused.
        try
        {
            Labelle.Batch<BatchPos>((ref BatchPos _) =>
                Labelle.Batch<BatchPos>((ref BatchPos _) => { }));
            Labelle.Log("CS_BULK_NESTED_ACCEPTED");
        }
        catch (BatchRefusedException) { Labelle.Log("CS_BULK_NESTED_REFUSED"); }

        // LAYOUT MISMATCH: "Plain" contributes zero stream floats while
        // the typed struct declares one — refused before any delegate call.
        Labelle.SetComponent(t1, "Plain", "{\"a\":2.5}");
        try
        {
            Labelle.Batch<BatchPos, PlainStream>((ref BatchPos _, ref PlainStream _) =>
                Labelle.Log("CS_BULK_MISMATCH_RAN"));
            Labelle.Log("CS_BULK_MISMATCH_ACCEPTED");
        }
        catch (BatchRefusedException) { Labelle.Log("CS_BULK_MISMATCH_REFUSED"); }

        // STALE-SET GUARD: destroy between the paired raw calls — the
        // exact-size preflight refuses, NOTHING is applied.
        var count = Labelle.BatchGet("[\"BatchPos\",\"BatchVel\"]", ref _raw, out var floats);
        for (var i = 0; i < floats; i++) _raw[i] += 100.0f;
        Labelle.DestroyEntity(t3);
        try
        {
            Labelle.BatchSet("[\"BatchPos\",\"BatchVel\"]", _raw, floats);
            Labelle.Log("CS_BULK_STALE_ACCEPTED");
        }
        catch (BatchRefusedException)
        {
            if (count == 3 && ReadX(t1) == 11.0f) Labelle.Log("CS_BULK_STALE_REFUSED");
        }

        // Drop the throwaways; mint the three steady-state entities the
        // Update iterator drives (asserted by id from the Zig side).
        Labelle.DestroyEntity(t1);
        Labelle.DestroyEntity(t2);
        for (var i = 0; i < 3; i++)
        {
            var it = Labelle.CreateEntity();
            Labelle.SetComponent(it, "BatchPos", $"{{\"x\":{i + 1},\"y\":0}}");
            Labelle.SetComponent(it, "BatchVel", "{\"vx\":10,\"vy\":-10}");
        }

        // Raw-tier sanity on the fresh set: one no-op round-trip pins the
        // count/stride and the exact-size write acceptance.
        var rc = Labelle.BatchGet("[\"BatchPos\",\"BatchVel\"]", ref _raw, out var rf);
        Labelle.BatchSet("[\"BatchPos\",\"BatchVel\"]", _raw, rf);
        Labelle.Log($"CS_BULK_RAW_{rc}_{rf}");
    }

    public override void Update(float dt)
    {
        _tick++;
        // The RFC's headline shape: the typed two-component iterator,
        // write-through refs over the stream buffer.
        var n = Labelle.Batch<BatchPos, BatchVel>((ref BatchPos bp, ref BatchVel bv) =>
        {
            bp.X += bv.Vx;
            bp.Y += bv.Vy;
            if (bp.X > 12.0f) bv.Vx = -bv.Vx; // bounce the third entity
        });
        if (_tick <= 2) Labelle.Log($"CS_BULK_ITER_{n}");
    }
}
