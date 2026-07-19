// The `Labelle` C# module — the Script Runtime Contract binding for game
// scripts written in C# (labelle-engine#743, the CoreCLR host family).
//
// There is no bindings layer to generate: the contract header
// (labelle-engine/contract/labelle_script.h) IS the binding — the
// `[LibraryImport]` declarations below mirror it 1:1, and the symbols
// resolve against the HOST PROCESS via the DllImportResolver installed in
// the module initializer (the labelle-engine#734 POC's finding #3, the
// CoreCLR spelling). The declared set is exactly the v1 core surface
// labelle-scripting binds today (src/contract.zig, SUPPORTED_CONTRACT_VERSION
// 1).
//
// Pointer spelling: the header's `const char *` is `byte*` — byte-identical
// ABI. Strings are (pointer, length) pairs, NOT NUL-terminated; structured
// payloads are UTF-8 JSON (encoding v1). Entity ids are `ulong` END TO END;
// 0 is the failure sentinel — no float and no signed int ever touches an id
// (a bit-63 id would drift).
//
// ## Allocation discipline (the RFC's C# idiom)
//
// C# strings are immutable and the marshaller allocates, so the reuse story
// mirrors rust's `&mut Vec<u8>` / crystal's `Buffer`: out-parameter wrappers
// take a caller-owned `ref byte[]` (held in a script's fields), grow it AT
// MOST ONCE per call via the contract's required-size legs, and scripts
// parse straight from the byte span (no per-read string). A script that
// keeps its buffers in fields reaches steady state after warm-up. The
// convenience overloads that return `string` are for cold paths.
//
// ## Scripts
//
// Game code lives in the game's `csharp/` dir, compiled into this assembly
// as the `Game` class (native-csharp/src/game/Game.cs is the placeholder the
// assembler stages the game's sources over). The convention is one entry
// point:
//
//     using Labelle;
//     public static class Game {
//         public static void Register(Scripts scripts) {
//             scripts.Add("player", new Player());
//         }
//     }
//
// and each script is a class deriving [Script], state in its fields. The
// glue (Glue.cs) drives the class from the plugin Controller's
// [UnmanagedCallersOnly] entry points and contains every exception at the
// FFI boundary — see its doc for hook order and exception semantics.

using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

// All types live in the GLOBAL namespace on purpose: the game-facing facade
// is a static class named `Labelle` (so scripts read `Labelle.Log(...)`, the
// C# spelling of rust's `labelle::log` / crystal's `Labelle.log`), and a
// namespace of the same name would shadow it. Game scripts therefore need no
// `using` at all — `Script`, `Scripts`, `EntityId` and `Labelle` are just
// there. The DLL loads in its own AssemblyLoadContext, so the global
// namespace is isolated from any other managed code in the host.

/// <summary>
/// The raw Script Runtime Contract imports (labelle_script.h v1). Internal
/// escape hatches; the <see cref="Labelle"/> facade is the supported surface.
/// Every call site owes the header's rules (main-thread only, borrowed
/// pointers, sizing legs).
/// </summary>
internal static unsafe partial class LabelleNative
{
    // The logical import library name; the resolver below maps it to the
    // host process so `labelle_*` binds against the game binary's exports.
    private const string LIB = "labelle";

    // Installed once when the assembly loads (before any Glue entry runs):
    // every `labelle_*` P/Invoke resolves against the MAIN PROGRAM handle —
    // the game binary that hosts this runtime and exports the contract. In
    // the repo's test binary the mock world (tests/mock_world.zig) is that
    // exporter; in a shipped game it is the assembler-generated main. The
    // host MUST export the symbols in its dynamic symbol table (rdynamic /
    // dllexport) — see the plugin README's csharp deployment notes.
    [ModuleInitializer]
    internal static void InstallResolver()
    {
        NativeLibrary.SetDllImportResolver(typeof(LabelleNative).Assembly, Resolve);
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        return libraryName == LIB ? NativeLibrary.GetMainProgramHandle() : IntPtr.Zero;
    }

    // ── Raw contract (signatures mirror labelle_script.h 1:1) ────────────

    [LibraryImport(LIB)]
    internal static partial uint labelle_contract_version();

    [LibraryImport(LIB)]
    internal static partial ulong labelle_entity_create();

    [LibraryImport(LIB)]
    internal static partial void labelle_entity_destroy(ulong id);

    [LibraryImport(LIB)]
    internal static partial ulong labelle_prefab_spawn(byte* name, nuint nameLen, byte* paramsJson, nuint paramsLen);

    [LibraryImport(LIB)]
    internal static partial int labelle_component_set(ulong id, byte* name, nuint nameLen, byte* json, nuint jsonLen);

    [LibraryImport(LIB)]
    internal static partial nuint labelle_component_get(ulong id, byte* name, nuint nameLen, byte* outBuf, nuint outCap);

    [LibraryImport(LIB)]
    internal static partial int labelle_component_has(ulong id, byte* name, nuint nameLen);

    [LibraryImport(LIB)]
    internal static partial int labelle_component_remove(ulong id, byte* name, nuint nameLen);

    [LibraryImport(LIB)]
    internal static partial nuint labelle_query(byte* namesJson, nuint namesJsonLen, byte* outBuf, nuint outCap);

    [LibraryImport(LIB)]
    internal static partial int labelle_event_emit(byte* name, nuint nameLen, byte* json, nuint jsonLen);

    [LibraryImport(LIB)]
    internal static partial void labelle_event_subscribe(byte* name, nuint nameLen);

    [LibraryImport(LIB)]
    internal static partial nuint labelle_event_poll(byte* outBuf, nuint outCap);

    [LibraryImport(LIB)]
    internal static partial int labelle_scene_change(byte* name, nuint nameLen);

    [LibraryImport(LIB)]
    internal static partial void labelle_log(byte* msg, nuint len);

    [LibraryImport(LIB)]
    internal static partial float labelle_time_dt();

    [LibraryImport(LIB)]
    internal static partial void labelle_time_dt_stamp(float dt);

    // ── Bulk component access (contract v1.3, labelle-scripting#41/#44) ──
    //
    // These bind the scripting plugin's ALWAYS-PRESENT Zig-side shims
    // (labelle-scripting src/bulk_shims.zig), NOT the contract's own
    // `labelle_component_*_packed`/`_batch_*` exports: those four symbols
    // exist only on engine hosts >= 2.6.0, and a direct import would make
    // the resolver fault against an older engine. The shims are
    // comptime-gated plugin-side — on a v1.3+ host they forward 1:1; on an
    // older host they answer the ordinary absent/refused sentinels (the
    // packed paths degrade to JSON silently) and
    // `labelle_scripting_bulk_capability` answers 0, which the batch
    // wrappers check FIRST and surface as the loud "needs labelle-engine
    // >= 2.6.0" exception (no batch fallback — silently degrading a
    // whole-query read would be data loss).

    [LibraryImport(LIB)]
    internal static partial uint labelle_scripting_bulk_capability();

    [LibraryImport(LIB)]
    internal static partial nuint labelle_scripting_bulk_get_packed(ulong id, byte* name, nuint nameLen, byte* outBuf, nuint outCap);

    [LibraryImport(LIB)]
    internal static partial int labelle_scripting_bulk_set_packed(ulong id, byte* name, nuint nameLen, byte* buf, nuint bufLen);

    [LibraryImport(LIB)]
    internal static partial nuint labelle_scripting_bulk_batch_get(byte* namesJson, nuint namesJsonLen, byte* outBuf, nuint outCap);

    [LibraryImport(LIB)]
    internal static partial int labelle_scripting_bulk_batch_set(byte* namesJson, nuint namesJsonLen, byte* buf, nuint bufLen);
}

/// <summary>Entity id, exactly as the contract carries it. 0 is never valid and doubles as the failure sentinel.</summary>
public readonly record struct EntityId(ulong Value)
{
    public static implicit operator ulong(EntityId id) => id.Value;
    public bool IsValid => Value != 0;
    public override string ToString() => Value.ToString();
}

/// <summary>
/// One game script: a class with per-frame state in its fields. Every hook
/// has a default empty body — override what you need.
///
/// Hook order per frame (driven by the plugin Controller through the glue):
/// <see cref="OnEvent"/> for every drained inbox entry (FIFO, last frame's
/// events), then <see cref="Update"/>. <see cref="Init"/> runs once at
/// plugin setup, <see cref="Deinit"/> at teardown (reverse registration
/// order).
///
/// Exception policy (enforced by the glue, pinned by the suite): a throw in
/// <see cref="Init"/> evicts the script — Update/Deinit never run on
/// half-initialized state; a throw in Update/OnEvent is caught and logged
/// EVERY time and the script stays registered; siblings always keep running.
/// No exception ever crosses the FFI boundary.
/// </summary>
public abstract class Script
{
    public virtual void Init() { }
    public virtual void Update(float dt) { }
    public virtual void OnEvent(string name, string payload) { }
    public virtual void Deinit() { }
}

/// <summary>
/// The registration collector handed to <c>Game.Register</c>. Names are
/// diagnostics identity: exception reports read "script '&lt;name&gt;' in
/// &lt;hook&gt;". Registration order is hook order (Init/OnEvent/Update run
/// in it; Deinit runs reversed).
/// </summary>
public sealed class Scripts
{
    internal readonly List<(string Name, Script Script)> Entries = new();

    public void Add(string name, Script script) => Entries.Add((name, script));
}

/// <summary>
/// One packed-codec scalar, tagged exactly as the wire tags it
/// (0=f32, 1=i64, 2=bool, 3=u64) — the value cell of the packed
/// per-component fast path (see <see cref="IPackedView"/>).
/// </summary>
public readonly struct Scalar
{
    public enum Kind : byte { F32 = 0, I64 = 1, Bool = 2, U64 = 3 }

    public readonly Kind Tag;
    private readonly float _f;
    private readonly long _bits; // i64 payload; u64 via bitcast; bool as 0/1

    private Scalar(Kind tag, float f, long bits) { Tag = tag; _f = f; _bits = bits; }

    public static Scalar F32(float v) => new(Kind.F32, v, 0);
    public static Scalar I64(long v) => new(Kind.I64, 0, v);
    /// <summary>u64 payload carried via two's-complement bitcast — the documented lossless pair.</summary>
    public static Scalar U64(ulong v) => new(Kind.U64, 0, unchecked((long)v));
    public static Scalar Bool(bool v) => new(Kind.Bool, 0, v ? 1 : 0);

    public float AsF32 => _f;
    public long AsI64 => _bits;
    public ulong AsU64 => unchecked((ulong)_bits);
    public bool AsBool => _bits != 0;

    // ── cross-class coercion (the JSON-fallback contract) ────────────
    // The JSON route types number tokens by SHAPE — `1` classifies as an
    // int even when the target field is f32, and both the host's
    // serializer and our own JSON-fallback encoder spell whole-number
    // floats that way. Views should assign through these Try* accessors
    // (see the IPackedView doc): int classes always land in a float
    // field (the host parser's own rounding); a FLOAT class lands in an
    // int field only when EXACT (finite, integral, in range — mirroring
    // the packed SET refusal rules); false = skip the field, keeping its
    // value. The 64-bit pair keeps its two's-complement bitcast.

    public bool TryF32(out float v)
    {
        switch (Tag)
        {
            case Kind.F32: v = _f; return true;
            case Kind.I64: v = _bits; return true;
            case Kind.U64: v = unchecked((ulong)_bits); return true;
            default: v = 0; return false;
        }
    }

    public bool TryI64(out long v)
    {
        switch (Tag)
        {
            case Kind.I64:
            case Kind.U64: // the bitcast pair
                v = _bits;
                return true;
            case Kind.F32:
                if (float.IsFinite(_f) && _f == MathF.Truncate(_f) &&
                    _f >= -9223372036854775808f && _f < 9223372036854775808f)
                {
                    v = (long)_f;
                    return true;
                }
                v = 0;
                return false;
            default: v = 0; return false;
        }
    }

    public bool TryU64(out ulong v)
    {
        switch (Tag)
        {
            case Kind.U64:
            case Kind.I64: // the bitcast pair
                v = unchecked((ulong)_bits);
                return true;
            case Kind.F32:
                if (float.IsFinite(_f) && _f == MathF.Truncate(_f) &&
                    _f >= 0f && _f < 18446744073709551616f)
                {
                    v = (ulong)_f;
                    return true;
                }
                v = 0;
                return false;
            default: v = 0; return false;
        }
    }

    public bool TryBool(out bool v)
    {
        v = _bits != 0;
        return Tag == Kind.Bool;
    }
}

/// <summary>
/// Receives one (name, value) pair per field during
/// <see cref="IPackedView.EachField"/> — the view's mechanical field walk,
/// shared by the packed encoder and the JSON fallback encoder.
/// </summary>
public interface IFieldSink
{
    void Field(string name, in Scalar v);
}

/// <summary>
/// A typed per-component view over the packed codec (contract v1.3) —
/// implement on a plain class whose fields mirror the component's:
/// <code>
/// sealed class StatsView : IPackedView {
///     public float Power; public long Score; public bool Alive; public ulong Seed;
///     public static string ComponentName => "Stats";
///     public bool SetField(ReadOnlySpan&lt;byte&gt; name, in Scalar v) { … }
///     public void EachField(IFieldSink sink) { … }
/// }
/// </code>
/// <see cref="Labelle.GetInto{T}"/> / <see cref="Labelle.SetFrom{T}"/> drive
/// the two methods; both are mechanical (compare the wire name, assign /
/// emit each field in declaration order). ASSIGN THROUGH THE
/// <c>Try*</c> ACCESSORS (<c>if (v.TryF32(out var f)) Power = f;</c>):
/// they implement the documented cross-class coercion — the JSON
/// fallback types whole-number floats as int-class tokens, which must
/// still land in float fields — and the codec's 64-bit two's-complement
/// bitcast pair (a ulong field accepts either 64-bit tag bit-exact).
/// </summary>
public interface IPackedView
{
    static abstract string ComponentName { get; }
    /// <summary>Assign one decoded field by wire name. False = not a view
    /// field (skipped — unmatched record fields are ignored).</summary>
    bool SetField(ReadOnlySpan<byte> name, in Scalar v);
    /// <summary>Visit every field in DECLARATION order.</summary>
    void EachField(IFieldSink sink);
}

/// <summary>
/// A typed per-entity view over the batch stream (contract v1.3) — a
/// struct of FLOAT FIELDS ONLY whose sequential fields mirror the
/// component's declaration order:
/// <code>
/// struct Pos : IBatchComponent { public float X, Y; public static string Name => "Pos"; }
/// </code>
/// <see cref="Labelle.Batch{T1,T2}"/> reinterprets each stream row as
/// <c>ref</c>s of these structs (zero copy, write-through — the RFC's
/// ref-struct/Span enumeration), so the struct's size IS the declared
/// stride, cross-checked against the host stream before the first call.
/// FLOAT-ONLY is enforced (a cached reflection check; the rust macro's
/// compile-time restriction, C#-spelled): a 1-byte CLR bool or an int
/// overlaid on a 4-byte float slot would read/write garbage — keep
/// bool/int-carrying components on the packed per-entity paths, or
/// model a flag as a float field compared against 0.
/// </summary>
public interface IBatchComponent
{
    static abstract string Name { get; }
}

/// <summary>The batch delegate shapes — <c>ref</c> parameters point INTO the
/// reused stream buffer (write-through). The <c>bool</c>-returning forms are
/// the early-exit tier: return false to stop iterating (writes made so far,
/// current row included, still COMMIT).</summary>
public delegate void BatchAction<T1>(ref T1 a);
public delegate void BatchAction<T1, T2>(ref T1 a, ref T2 b);
public delegate bool BatchFunc<T1>(ref T1 a);
public delegate bool BatchFunc<T1, T2>(ref T1 a, ref T2 b);

/// <summary>
/// A batch call refused (loud on purpose — there is no batch fallback):
/// the host engine lacks bulk access (needs labelle-engine >= 2.6.0), the
/// entity set changed between the paired get/set (nothing was applied —
/// re-run and recompute), or the typed views' stride does not match the
/// host stream. Int-typed-field refusals throw
/// <see cref="ArgumentException"/> instead, mirroring the ruby binding's
/// class split.
/// </summary>
public sealed class BatchRefusedException : InvalidOperationException
{
    public BatchRefusedException(string message) : base(message) { }
}

/// <summary>
/// The safe wrapper surface every script uses. Mirrors the rust/crystal
/// `labelle` module: entities, components-by-name (JSON), queries, events
/// (subscribe + poll-drain), prefabs, scene, log, time.
/// </summary>
public static unsafe class Labelle
{
    /// <summary>Contract version the host binary was built with.</summary>
    public static uint ContractVersion() => LabelleNative.labelle_contract_version();

    // ── Entities ─────────────────────────────────────────────────────────

    /// <summary>Create an empty entity. Returns 0 when the host is not bound.</summary>
    public static EntityId CreateEntity() => new(LabelleNative.labelle_entity_create());

    /// <summary>Destroy an entity (children cascade). Unknown / dead ids are ignored.</summary>
    public static void DestroyEntity(EntityId id) => LabelleNative.labelle_entity_destroy(id);

    /// <summary>Spawn a named prefab. <paramref name="paramsJson"/> is an optional
    /// {"x":…,"y":…} spawn position; null spawns at the origin. Returns 0 on failure.</summary>
    public static EntityId SpawnPrefab(string name, string? paramsJson = null)
    {
        var nb = Encoding.UTF8.GetBytes(name);
        var pb = paramsJson is null ? Array.Empty<byte>() : Encoding.UTF8.GetBytes(paramsJson);
        fixed (byte* np = nb)
        fixed (byte* pp = pb)
            return new(LabelleNative.labelle_prefab_spawn(np, (nuint)nb.Length, pp, (nuint)pb.Length));
    }

    // ── Components ─────────────────────────────────────────────────────────

    /// <summary>REPLACE-semantics set from a whole-struct JSON object (absent fields
    /// take declared defaults). False = unknown component / dead entity / parse error.</summary>
    public static bool SetComponent(EntityId id, string name, string json)
    {
        var nb = Encoding.UTF8.GetBytes(name);
        var jb = Encoding.UTF8.GetBytes(json);
        fixed (byte* np = nb)
        fixed (byte* jp = jb)
            return LabelleNative.labelle_component_set(id, np, (nuint)nb.Length, jp, (nuint)jb.Length) == 0;
    }

    /// <summary>
    /// Serialize component <paramref name="name"/> of <paramref name="id"/> into
    /// <paramref name="buf"/> (grown AT MOST ONCE via the contract's required-size
    /// return; ALL-OR-NOTHING write). Returns the number of valid bytes at the
    /// start of <paramref name="buf"/>, 0 = absent / unknown / dead. This is the
    /// steady-state, reuse-friendly path — hold <paramref name="buf"/> in a field.
    /// </summary>
    public static int GetComponentInto(EntityId id, string name, ref byte[] buf)
    {
        var nb = Encoding.UTF8.GetBytes(name);
        nuint required;
        fixed (byte* np = nb)
        fixed (byte* bp = buf)
            required = LabelleNative.labelle_component_get(id, np, (nuint)nb.Length, bp, (nuint)buf.Length);
        if (required == 0) return 0;
        if (required <= (nuint)buf.Length) return (int)required;
        // Grow once, right-sized, and retry.
        buf = new byte[required];
        fixed (byte* np = nb)
        fixed (byte* bp = buf)
            required = LabelleNative.labelle_component_get(id, np, (nuint)nb.Length, bp, (nuint)buf.Length);
        return required <= (nuint)buf.Length ? (int)required : 0;
    }

    /// <summary>Convenience: the component JSON as a string, or null. Cold-path — allocates.</summary>
    public static string? GetComponent(EntityId id, string name)
    {
        byte[] buf = Array.Empty<byte>();
        var n = GetComponentInto(id, name, ref buf);
        return n == 0 ? null : Encoding.UTF8.GetString(buf, 0, n);
    }

    /// <summary>True when the entity carries the component.</summary>
    public static bool ComponentHas(EntityId id, string name)
    {
        var nb = Encoding.UTF8.GetBytes(name);
        fixed (byte* np = nb)
            return LabelleNative.labelle_component_has(id, np, (nuint)nb.Length) == 1;
    }

    /// <summary>Remove the component. Idempotent. False = unknown name / dead entity.</summary>
    public static bool RemoveComponent(EntityId id, string name)
    {
        var nb = Encoding.UTF8.GetBytes(name);
        fixed (byte* np = nb)
            return LabelleNative.labelle_component_remove(id, np, (nuint)nb.Length) == 0;
    }

    // ── Queries ────────────────────────────────────────────────────────────

    /// <summary>
    /// Query entity ids by component names. <paramref name="namesJson"/> is the
    /// contract's JSON array of names (pass a literal like <c>["Hunger","Worker"]</c>).
    /// Ids land in <paramref name="ids"/> (cleared, capacity retained); <paramref name="scratch"/>
    /// carries the host JSON between the sizing legs and grows AT MOST ONCE. False =
    /// malformed input / not bound; unknown names yield an empty result (true, no ids).
    /// </summary>
    public static bool QueryInto(string namesJson, List<EntityId> ids, ref byte[] scratch)
    {
        ids.Clear();
        var qb = Encoding.UTF8.GetBytes(namesJson);
        nuint required;
        fixed (byte* qp = qb)
        fixed (byte* sp = scratch)
            required = LabelleNative.labelle_query(qp, (nuint)qb.Length, sp, (nuint)scratch.Length);
        if (required == 0) return false;
        int len;
        if (required > (nuint)scratch.Length)
        {
            scratch = new byte[required];
            nuint got;
            fixed (byte* qp = qb)
            fixed (byte* sp = scratch)
                got = LabelleNative.labelle_query(qp, (nuint)qb.Length, sp, (nuint)scratch.Length);
            if (got == 0) return false;
            len = (int)Math.Min(got, (nuint)scratch.Length);
        }
        else
        {
            len = (int)required;
        }
        ParseIds(scratch.AsSpan(0, len), ids);
        return true;
    }

    /// <summary>Parse a contract id-array (<c>[3,7,12]</c>) into <paramref name="ids"/>
    /// (cleared first). Pure ulong arithmetic — a bit-63 id survives exactly.</summary>
    public static void ParseIds(ReadOnlySpan<byte> json, List<EntityId> ids)
    {
        ids.Clear();
        ulong cur = 0;
        bool inNum = false;
        foreach (var b in json)
        {
            if (b >= (byte)'0' && b <= (byte)'9')
            {
                cur = cur * 10 + (ulong)(b - (byte)'0');
                inNum = true;
            }
            else if (inNum)
            {
                ids.Add(new(cur));
                cur = 0;
                inNum = false;
            }
        }
        if (inNum) ids.Add(new(cur));
    }

    // ── Events ─────────────────────────────────────────────────────────────

    /// <summary>Emit a game event by union-tag name. Empty json means "{}". False =
    /// unknown event name / parse failure / the game declares no events.</summary>
    public static bool Emit(string name, string json = "")
    {
        var nb = Encoding.UTF8.GetBytes(name);
        var jb = Encoding.UTF8.GetBytes(json);
        fixed (byte* np = nb)
        fixed (byte* jp = jb)
            return LabelleNative.labelle_event_emit(np, (nuint)nb.Length, jp, (nuint)jb.Length) == 0;
    }

    /// <summary>Declare interest in an event name (dedup'd host-side). Delivery starts
    /// with the next tick's events, through <see cref="Script.OnEvent"/> — the glue owns the drain.</summary>
    public static void Subscribe(string name)
    {
        var nb = Encoding.UTF8.GetBytes(name);
        fixed (byte* np = nb)
            LabelleNative.labelle_event_subscribe(np, (nuint)nb.Length);
    }

    /// <summary>
    /// Drain one pending "&lt;name&gt; &lt;json&gt;" inbox entry into
    /// <paramref name="buf"/> (grown AT MOST ONCE via the no-consume probe).
    /// Returns the valid byte count, 0 = inbox empty. The glue calls this once per
    /// entry per tick and fans out to <see cref="Script.OnEvent"/> — scripts normally
    /// never call it themselves (a script-side poll would STEAL entries).
    /// </summary>
    public static int PollInto(ref byte[] buf)
    {
        // No-consume sizing probe (NULL/cap-0), then the real read.
        nuint next = LabelleNative.labelle_event_poll(null, 0);
        if (next == 0) return 0;
        if (next > (nuint)buf.Length) buf = new byte[next];
        nuint written;
        fixed (byte* bp = buf)
            written = LabelleNative.labelle_event_poll(bp, (nuint)buf.Length);
        return written == 0 || written > (nuint)buf.Length ? 0 : (int)written;
    }

    // ── Scene / log / time ───────────────────────────────────────────────

    /// <summary>Switch to a registered scene by name. False = unknown scene / not bound.</summary>
    public static bool ChangeScene(string name)
    {
        var nb = Encoding.UTF8.GetBytes(name);
        fixed (byte* np = nb)
            return LabelleNative.labelle_scene_change(np, (nuint)nb.Length) == 0;
    }

    /// <summary>Log through the game's log sink at info level, "[script]"-prefixed.</summary>
    public static void Log(string msg)
    {
        var mb = Encoding.UTF8.GetBytes(msg);
        fixed (byte* mp = mb)
            LabelleNative.labelle_log(mp, (nuint)mb.Length);
    }

    /// <summary>The tick's gameplay delta-time in seconds — the same scaled dt Zig
    /// scripts received (0 while paused and before the first tick).</summary>
    public static float Dt() => LabelleNative.labelle_time_dt();

    // ── Bulk component access (contract v1.3, labelle-scripting#41/#44) ──
    //
    // The packed per-component codec and the batched whole-query f32
    // stream, ported from the Ruby reference (src/ruby/bindings.zig +
    // prelude.rb). Capability gating rides the plugin's Zig-side shims —
    // see LabelleNative's bulk section doc.
    //
    // NON-FINITE POLICY (parity with this family's JSON route): C#
    // scripts hand-write JSON, where NaN/Inf have no spelling — a
    // hand-built {"power":NaN} is refused by the host parser (-1 →
    // false). The packed fast path must not smuggle values the JSON
    // route cannot carry, so SetFrom refuses a non-finite float field up
    // front (false, nothing written) and BatchSet refuses a non-finite
    // stream element the same way (ArgumentException, nothing written —
    // #45). The dynamic families guard "finite f64 that narrows to inf"
    // after the f32 narrow; here the view fields ARE float, so such a
    // value arrives already as Infinity and the same refusals catch it.

    /// <summary>labelle_component_batch_get's int-field refusal sentinel —
    /// the header's LABELLE_BATCH_INT_REFUSED, C's (size_t)-2. Checked
    /// BEFORE treating the return as a required size.</summary>
    public static readonly nuint BatchIntRefused = unchecked((nuint)(nint)(-2));

    /// <summary>True when the host engine exports the contract v1.3
    /// bulk-access symbols (labelle-engine >= 2.6.0) — the runtime
    /// spelling of the plugin's comptime probe.</summary>
    public static bool BulkAccess => LabelleNative.labelle_scripting_bulk_capability() == 1;

    // Cached UTF-8 component names / names-JSON per view type (built once
    // per generic instantiation — the steady state allocates nothing).
    private static class PackedName<T> where T : IPackedView
    {
        public static readonly byte[] Utf8 = Encoding.UTF8.GetBytes(T.ComponentName);
        public static readonly string Name = T.ComponentName;
    }

    private static class BatchNames<T1> where T1 : IBatchComponent
    {
        public static readonly byte[] Json = Encoding.UTF8.GetBytes($"[\"{T1.Name}\"]");
        public static readonly string Text = $"[\"{T1.Name}\"]";
    }

    private static class BatchNames<T1, T2>
        where T1 : IBatchComponent
        where T2 : IBatchComponent
    {
        public static readonly byte[] Json = Encoding.UTF8.GetBytes($"[\"{T1.Name}\",\"{T2.Name}\"]");
        public static readonly string Text = $"[\"{T1.Name}\",\"{T2.Name}\"]";
    }

    // The field-collect sink shared by SetFrom's packed encoder and its
    // JSON fallback — one reused list, cleared per call (main-thread only,
    // like every contract call).
    private sealed class CollectSink : IFieldSink
    {
        public readonly List<(string Name, Scalar V)> Fields = new();
        public void Field(string name, in Scalar v) => Fields.Add((name, v));
    }

    [ThreadStatic] private static CollectSink? _collect;
    [ThreadStatic] private static byte[]? _packedScratch;

    /// <summary>
    /// Refill <paramref name="view"/> from component
    /// <c>T.ComponentName</c> of <paramref name="id"/> — the
    /// per-component FAST PATH. Tries the packed codec first (scalars
    /// land straight in the typed fields, no JSON parse); a 0xFF first
    /// byte (non-scalar component), an absent component, or a pre-v1.3
    /// host drops to the JSON route transparently. <paramref name="scratch"/>
    /// is the reused byte buffer (grown at most once per leg — hold it in
    /// a field). False = absent / unknown / dead.
    /// </summary>
    public static bool GetInto<T>(EntityId id, T view, ref byte[] scratch) where T : IPackedView
    {
        ArgumentNullException.ThrowIfNull(view);
        ArgumentNullException.ThrowIfNull(scratch);
        var nb = PackedName<T>.Utf8;
        nuint n;
        fixed (byte* np = nb)
        fixed (byte* bp = scratch)
            n = LabelleNative.labelle_scripting_bulk_get_packed(id, np, (nuint)nb.Length, bp, (nuint)scratch.Length);
        if (n > (nuint)scratch.Length)
        {
            scratch = new byte[n];
            fixed (byte* np = nb)
            fixed (byte* bp = scratch)
                n = LabelleNative.labelle_scripting_bulk_get_packed(id, np, (nuint)nb.Length, bp, (nuint)scratch.Length);
        }
        if (n >= 1 && n <= (nuint)scratch.Length && scratch[0] != 0xFF)
        {
            DecodePackedInto(scratch.AsSpan(0, (int)n), view);
            return true;
        }
        // n == 0 (absent / pre-v1.3 host) or 0xFF (non-scalar component):
        // the JSON route decides — absent stays false there too.
        var len = GetComponentInto(id, PackedName<T>.Name, ref scratch);
        if (len == 0) return false;
        JsonScalarFields(scratch.AsSpan(0, len), view);
        return true;
    }

    /// <summary>
    /// Write <paramref name="view"/> to component <c>T.ComponentName</c>
    /// of <paramref name="id"/> — the per-component FAST PATH (REPLACE
    /// semantics, like <see cref="SetComponent"/>). Encodes the packed
    /// record (each field tagged by its <see cref="Scalar"/> kind); a host
    /// refusal (-1: non-packable component, out-of-range value, pre-v1.3
    /// host) falls back to a sorted-key JSON encode of the same fields. A
    /// NON-FINITE float field refuses up front (false, nothing written) —
    /// see the section doc. False = refused / unknown / dead.
    /// </summary>
    public static bool SetFrom<T>(EntityId id, T view) where T : IPackedView
    {
        ArgumentNullException.ThrowIfNull(view);
        var sink = _collect ??= new CollectSink();
        sink.Fields.Clear();
        view.EachField(sink);
        foreach (var (_, v) in sink.Fields)
        {
            if (v.Tag == Scalar.Kind.F32 && !float.IsFinite(v.AsF32)) return false;
        }
        var nb = PackedName<T>.Utf8;
        Span<byte> rec = stackalloc byte[2048];
        if (EncodePacked(sink.Fields, rec, out var recLen))
        {
            int rc;
            fixed (byte* np = nb)
            fixed (byte* rp = rec)
                rc = LabelleNative.labelle_scripting_bulk_set_packed(id, np, (nuint)nb.Length, rp, (nuint)recLen);
            if (rc == 0) return true;
            // Refused — fall through to JSON, which represents the value
            // faithfully (or refuses loudly host-side).
        }
        // JSON fallback: deterministic sorted-key encode (the ruby
        // binding's convention). Cold path — allocates.
        sink.Fields.Sort(static (a, b) => string.CompareOrdinal(a.Name, b.Name));
        var sb = new StringBuilder(16 + sink.Fields.Count * 16);
        sb.Append('{');
        for (var i = 0; i < sink.Fields.Count; i++)
        {
            if (i > 0) sb.Append(',');
            var (name, v) = sink.Fields[i];
            sb.Append('"').Append(name).Append("\":");
            switch (v.Tag)
            {
                case Scalar.Kind.F32:
                    sb.Append(v.AsF32.ToString(System.Globalization.CultureInfo.InvariantCulture));
                    break;
                case Scalar.Kind.I64:
                    sb.Append(v.AsI64);
                    break;
                case Scalar.Kind.U64:
                    sb.Append(v.AsU64);
                    break;
                default:
                    sb.Append(v.AsBool ? "true" : "false");
                    break;
            }
        }
        sb.Append('}');
        return SetComponent(id, PackedName<T>.Name, sb.ToString());
    }

    /// <summary>Decode a packed component record (the host's _get_packed
    /// wire format) into the view: for each field record, assign by name.
    /// A malformed record stops early (fields decoded so far stay applied)
    /// — the host builds it, so this is belt-and-suspenders.</summary>
    private static void DecodePackedInto<T>(ReadOnlySpan<byte> rec, T view) where T : IPackedView
    {
        if (rec.IsEmpty) return;
        int fieldCount = rec[0];
        var pos = 1;
        for (var i = 0; i < fieldCount; i++)
        {
            if (pos >= rec.Length) return;
            int nameLen = rec[pos];
            pos += 1;
            if (pos + nameLen > rec.Length) return;
            var name = rec.Slice(pos, nameLen);
            pos += nameLen;
            if (pos >= rec.Length) return;
            var tag = rec[pos];
            pos += 1;
            Scalar v;
            switch (tag)
            {
                case 0:
                    if (pos + 4 > rec.Length) return;
                    v = Scalar.F32(System.Buffers.Binary.BinaryPrimitives.ReadSingleLittleEndian(rec.Slice(pos, 4)));
                    pos += 4;
                    break;
                case 1:
                    if (pos + 8 > rec.Length) return;
                    v = Scalar.I64(System.Buffers.Binary.BinaryPrimitives.ReadInt64LittleEndian(rec.Slice(pos, 8)));
                    pos += 8;
                    break;
                case 2:
                    if (pos >= rec.Length) return;
                    v = Scalar.Bool(rec[pos] != 0);
                    pos += 1;
                    break;
                case 3:
                    if (pos + 8 > rec.Length) return;
                    v = Scalar.U64(System.Buffers.Binary.BinaryPrimitives.ReadUInt64LittleEndian(rec.Slice(pos, 8)));
                    pos += 8;
                    break;
                default:
                    return;
            }
            view.SetField(name, v);
        }
    }

    /// <summary>Encode the collected fields as a packed record (the
    /// _set_packed wire format). False = doesn't fit (the caller takes the
    /// JSON path).</summary>
    private static bool EncodePacked(List<(string Name, Scalar V)> fields, Span<byte> rec, out int len)
    {
        len = 0;
        if (fields.Count > 255) return false;
        var w = 1;
        foreach (var (name, v) in fields)
        {
            var payload = v.Tag switch
            {
                Scalar.Kind.F32 => 4,
                Scalar.Kind.Bool => 1,
                _ => 8,
            };
            var nameLen = Encoding.UTF8.GetByteCount(name);
            if (nameLen > 255 || w + 1 + nameLen + 1 + payload > rec.Length) return false;
            rec[w] = (byte)nameLen;
            w += 1;
            Encoding.UTF8.GetBytes(name, rec.Slice(w, nameLen));
            w += nameLen;
            switch (v.Tag)
            {
                case Scalar.Kind.F32:
                    rec[w] = 0;
                    System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(rec.Slice(w + 1, 4), v.AsF32);
                    w += 5;
                    break;
                case Scalar.Kind.I64:
                    rec[w] = 1;
                    System.Buffers.Binary.BinaryPrimitives.WriteInt64LittleEndian(rec.Slice(w + 1, 8), v.AsI64);
                    w += 9;
                    break;
                case Scalar.Kind.Bool:
                    rec[w] = 2;
                    rec[w + 1] = v.AsBool ? (byte)1 : (byte)0;
                    w += 2;
                    break;
                default:
                    rec[w] = 3;
                    System.Buffers.Binary.BinaryPrimitives.WriteUInt64LittleEndian(rec.Slice(w + 1, 8), v.AsU64);
                    w += 9;
                    break;
            }
        }
        rec[0] = (byte)fields.Count;
        len = w;
        return true;
    }

    /// <summary>Walk a FLAT JSON object's scalar members into the view:
    /// numbers type by token shape (fraction/exponent → f32; else i64 when
    /// negative, u64 otherwise — the mock/engine convention); bools pass
    /// through; nested values, strings and null are skipped, exactly as
    /// the packed stream skips non-scalar fields. The JSON-fallback decode
    /// half of <see cref="GetInto{T}"/>.</summary>
    private static void JsonScalarFields<T>(ReadOnlySpan<byte> json, T view) where T : IPackedView
    {
        var i = SkipWs(json, 0);
        if (i >= json.Length || json[i] != (byte)'{') return;
        i++;
        while (true)
        {
            i = SkipWs(json, i);
            if (i >= json.Length || json[i] == (byte)'}') return;
            if (json[i] != (byte)'"') return;
            i++;
            var keyStart = i;
            while (i < json.Length && json[i] != (byte)'"') i++; // names are identifiers — no escapes
            if (i >= json.Length) return;
            var keyEnd = i;
            i++;
            i = SkipWs(json, i);
            if (i >= json.Length || json[i] != (byte)':') return;
            i++;
            i = SkipWs(json, i);
            if (i >= json.Length) return;
            var b0 = json[i];
            if (b0 == (byte)'{' || b0 == (byte)'[')
            {
                var depth = 0;
                var inStr = false;
                while (i < json.Length)
                {
                    var b = json[i];
                    if (inStr)
                    {
                        if (b == (byte)'\\') i++;
                        else if (b == (byte)'"') inStr = false;
                    }
                    else if (b == (byte)'"') inStr = true;
                    else if (b == (byte)'{' || b == (byte)'[') depth++;
                    else if (b == (byte)'}' || b == (byte)']')
                    {
                        depth--;
                        if (depth == 0) { i++; break; }
                    }
                    i++;
                }
            }
            else if (b0 == (byte)'"')
            {
                i++;
                while (i < json.Length)
                {
                    if (json[i] == (byte)'\\') i++;
                    else if (json[i] == (byte)'"') { i++; break; }
                    i++;
                }
            }
            else
            {
                var start = i;
                while (i < json.Length && json[i] != (byte)',' && json[i] != (byte)'}') i++;
                var tok = json[start..i].Trim(" \t\r\n"u8);
                if (ClassifyToken(tok, out var v))
                    view.SetField(json[keyStart..keyEnd], v);
            }
            i = SkipWs(json, i);
            if (i < json.Length && json[i] == (byte)',') { i++; continue; }
            return;
        }
    }

    private static int SkipWs(ReadOnlySpan<byte> json, int i)
    {
        while (i < json.Length && (json[i] == (byte)' ' || json[i] == (byte)'\t' || json[i] == (byte)'\n' || json[i] == (byte)'\r')) i++;
        return i;
    }

    private static bool ClassifyToken(ReadOnlySpan<byte> tok, out Scalar v)
    {
        v = default;
        if (tok.IsEmpty) return false;
        if (tok.SequenceEqual("true"u8)) { v = Scalar.Bool(true); return true; }
        if (tok.SequenceEqual("false"u8)) { v = Scalar.Bool(false); return true; }
        var fractional = tok.IndexOfAny((byte)'.', (byte)'e', (byte)'E') >= 0;
        if (!fractional)
        {
            if (tok[0] == (byte)'-')
            {
                if (System.Buffers.Text.Utf8Parser.TryParse(tok, out long l, out var c1) && c1 == tok.Length)
                {
                    v = Scalar.I64(l);
                    return true;
                }
            }
            else if (System.Buffers.Text.Utf8Parser.TryParse(tok, out ulong u, out var c2) && c2 == tok.Length)
            {
                v = Scalar.U64(u);
                return true;
            }
        }
        if (System.Buffers.Text.Utf8Parser.TryParse(tok, out float f, out var c3) && c3 == tok.Length)
        {
            v = Scalar.F32(f);
            return true;
        }
        return false;
    }

    // ── Batched query (the whole-query fast path) ────────────────────────

    private static void ThrowBatchUnsupported() =>
        throw new BatchRefusedException(
            "labelle: batch — the host engine lacks batch support (script contract v1.3 " +
            "needs labelle-engine >= 2.6.0); use per-entity get/set on this engine");

    private static void ThrowBatchIntRefused(string namesJson) =>
        throw new ArgumentException(
            $"labelle: batch refused for {namesJson}: a named component has an int-typed " +
            "field (i64/u64 cannot ride the f32 batch stream) — keep that component on " +
            "per-entity get/set (the packed codec carries ints losslessly)");

    /// <summary>
    /// ONE contract crossing fills <paramref name="buf"/> with every
    /// matching entity's scalar component data as a flat f32 stream
    /// ([c0_f0, c0_f1, …] per entity, components in
    /// <paramref name="namesJson"/> order, fields in declaration order).
    /// Returns the entity COUNT; <paramref name="floatCount"/> is the
    /// number of valid floats at the start of <paramref name="buf"/>
    /// (exactly count×stride — pass it back to
    /// <see cref="BatchSet"/>). The buffer grows at most once and is
    /// reused. 0 = empty query (also malformed names / not bound — the
    /// ruby convention). The raw tier: the script owns the positional
    /// layout. Throws <see cref="ArgumentException"/> on an int-carrying
    /// named component, <see cref="BatchRefusedException"/> on a pre-v1.3
    /// host.
    /// </summary>
    public static int BatchGet(string namesJson, ref float[] buf, out int floatCount)
    {
        ArgumentNullException.ThrowIfNull(namesJson);
        ArgumentNullException.ThrowIfNull(buf);
        floatCount = 0;
        if (!BulkAccess) ThrowBatchUnsupported();
        var scratch = _packedScratch ??= new byte[4096];
        var qb = Encoding.UTF8.GetBytes(namesJson);
        nuint n;
        fixed (byte* qp = qb)
        fixed (byte* sp = scratch)
            n = LabelleNative.labelle_scripting_bulk_batch_get(qp, (nuint)qb.Length, sp, (nuint)scratch.Length);
        // The refusal sentinel is (size_t)-2 — check BEFORE reading the
        // return as a required size.
        if (n == BatchIntRefused) ThrowBatchIntRefused(namesJson);
        if (n == 0) return 0;
        if (n > (nuint)scratch.Length)
        {
            scratch = _packedScratch = new byte[n];
            fixed (byte* qp = qb)
            fixed (byte* sp = scratch)
                n = LabelleNative.labelle_scripting_bulk_batch_get(qp, (nuint)qb.Length, sp, (nuint)scratch.Length);
            if (n == 0 || n > (nuint)scratch.Length) return 0; // belt — mirrors ruby
        }
        if (n < 4) return 0;
        var bytes = scratch.AsSpan(0, (int)n);
        var count = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(bytes);
        floatCount = (bytes.Length - 4) / 4;
        if (buf.Length < floatCount) buf = new float[floatCount];
        for (var i = 0; i < floatCount; i++)
            buf[i] = System.Buffers.Binary.BinaryPrimitives.ReadSingleLittleEndian(bytes.Slice(4 + i * 4, 4));
        return count;
    }

    /// <summary>
    /// ONE contract crossing writes the whole stream back: the host
    /// re-queries the same entities in the same order and applies the
    /// first <paramref name="floatCount"/> floats of
    /// <paramref name="buf"/> positionally, read-modify-write per
    /// component. Throws <see cref="ArgumentException"/> on int-typed
    /// fields, <see cref="BatchRefusedException"/> when the entity set
    /// changed since the paired <see cref="BatchGet"/> (NOTHING was
    /// applied — re-run and recompute) or on a pre-v1.3 host.
    /// </summary>
    public static void BatchSet(string namesJson, float[] buf, int floatCount)
    {
        ArgumentNullException.ThrowIfNull(namesJson);
        ArgumentNullException.ThrowIfNull(buf);
        if (!BulkAccess) ThrowBatchUnsupported();
        // Non-finite refusal at the BINDING (#45) — one branch-predictable
        // pass, cheap next to the FFI crossing: NaN/Inf must never ride
        // into component fields, and the refusal happens BEFORE anything
        // is handed to the host (all-or-nothing). A finite-but-
        // f32-overflowing value cannot arise here: the elements ARE
        // float, so an overflow is born as Infinity and lands on this
        // same refusal.
        for (var i = 0; i < floatCount; i++)
        {
            if (!float.IsFinite(buf[i]))
                throw new ArgumentException(
                    $"labelle: batch_set: non-finite number at element {i} — the f32 stream " +
                    "refuses NaN/Inf, the json-route non-finite policy (nothing was written)");
        }
        var scratch = _packedScratch ??= new byte[4096];
        if (scratch.Length < floatCount * 4) scratch = _packedScratch = new byte[floatCount * 4];
        for (var i = 0; i < floatCount; i++)
            System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(scratch.AsSpan(i * 4, 4), buf[i]);
        var qb = Encoding.UTF8.GetBytes(namesJson);
        int rc;
        fixed (byte* qp = qb)
        fixed (byte* sp = scratch)
            rc = LabelleNative.labelle_scripting_bulk_batch_set(qp, (nuint)qb.Length, sp, (nuint)(floatCount * 4));
        if (rc == -2) ThrowBatchIntRefused(namesJson);
        if (rc != 0)
            throw new BatchRefusedException(
                $"labelle: batch_set refused for {namesJson}: the entity set changed between " +
                "batch_get and batch_set (spawn/destroy between the paired calls — the buffer " +
                "was computed against a stale set; re-run batch_get and recompute), or the " +
                "names were malformed / the host not bound");
    }

    // The reused iterator-tier buffer + the no-nesting latch. A nested
    // Batch call would alias the buffer mid-iteration (and the refs handed
    // to the delegate point INTO it), so it throws instead of corrupting.
    [ThreadStatic] private static float[]? _batchBuf;
    [ThreadStatic] private static bool _batchActive;

    /// <summary>
    /// The JIT-friendly typed iterator over one component (the RFC's
    /// headline, single-component form): ONE <see cref="BatchGet"/>, the
    /// delegate runs once per matching entity with <c>ref</c> views
    /// reinterpreted IN PLACE over the stream buffer (zero copy,
    /// write-through — CoreCLR inlines the delegate and this approaches
    /// the flat loop), then ONE <see cref="BatchSet"/> commits. Returns
    /// the entity count; an empty query returns 0 without invoking the
    /// delegate.
    ///
    /// EXIT SEMANTICS (the ruby contract, C# spelling): completing the
    /// delegate for every row COMMITS; early exit is
    /// <see cref="BatchWhile{T1}"/> (return false) and COMMITS the writes
    /// made so far — the refs are write-through, so the current row's
    /// writes are included; an EXCEPTION thrown from the delegate aborts
    /// the whole write (<see cref="BatchSet"/> never runs —
    /// all-or-nothing; the glue contains it at the hook boundary like any
    /// script exception).
    /// </summary>
    public static int Batch<T1>(BatchAction<T1> f)
        where T1 : unmanaged, IBatchComponent
    {
        ArgumentNullException.ThrowIfNull(f);
        return BatchWhile<T1>((ref T1 a) =>
        {
            f(ref a);
            return true;
        });
    }

    /// <summary><see cref="Batch{T1}"/> with early exit: return false to
    /// stop iterating — writes made so far (current row included) still
    /// COMMIT.</summary>
    public static int BatchWhile<T1>(BatchFunc<T1> f)
        where T1 : unmanaged, IBatchComponent
    {
        ArgumentNullException.ThrowIfNull(f);
        var s1 = ViewStride<T1>();
        return BatchCore(BatchNames<T1>.Text, s1, (span, stride, count) =>
        {
            for (var i = 0; i < count; i++)
            {
                ref var a = ref System.Runtime.CompilerServices.Unsafe.As<float, T1>(ref span[i * stride]);
                if (!f(ref a)) break;
            }
        });
    }

    /// <summary>The two-component form — the RFC's
    /// <c>Batch&lt;Position, Velocity&gt;((ref p, ref v) =&gt; …)</c>
    /// headline. Semantics of <see cref="Batch{T1}"/>.</summary>
    public static int Batch<T1, T2>(BatchAction<T1, T2> f)
        where T1 : unmanaged, IBatchComponent
        where T2 : unmanaged, IBatchComponent
    {
        ArgumentNullException.ThrowIfNull(f);
        return BatchWhile<T1, T2>((ref T1 a, ref T2 b) =>
        {
            f(ref a, ref b);
            return true;
        });
    }

    /// <summary><see cref="Batch{T1,T2}"/> with early exit — false stops
    /// iterating and COMMITS the writes made so far.</summary>
    public static int BatchWhile<T1, T2>(BatchFunc<T1, T2> f)
        where T1 : unmanaged, IBatchComponent
        where T2 : unmanaged, IBatchComponent
    {
        ArgumentNullException.ThrowIfNull(f);
        // Duplicate component names would put two copies of the same
        // fields in every row and let the unchanged copy overwrite the
        // other's writes on the positional write-back — refuse before
        // any host call (the ruby block tier's duplicate-name refusal,
        // one level up).
        if (T1.Name == T2.Name)
            throw new ArgumentException(
                $"labelle: Batch: component '{T1.Name}' is named by both views — the " +
                "stream would carry two copies per entity and the write-back would " +
                "silently lose one's writes; batch each component once");
        var s1 = ViewStride<T1>();
        var s2 = ViewStride<T2>();
        return BatchCore(BatchNames<T1, T2>.Text, s1 + s2, (span, stride, count) =>
        {
            for (var i = 0; i < count; i++)
            {
                ref var a = ref System.Runtime.CompilerServices.Unsafe.As<float, T1>(ref span[i * stride]);
                ref var b = ref System.Runtime.CompilerServices.Unsafe.As<float, T2>(ref span[i * stride + s1]);
                if (!f(ref a, ref b)) break;
            }
        });
    }

    private delegate void BatchRowLoop(Span<float> span, int stride, int count);

    /// <summary>
    /// Per-view-type validation + stride, computed ONCE per generic
    /// instantiation: a batch view must be a sequential struct of FLOAT
    /// FIELDS ONLY — the rows are reinterpreted in place over the f32
    /// stream (zero copy), so any other field type (a 1-byte CLR bool,
    /// an int) would read/write raw float bits as garbage. This is the
    /// same restriction rust enforces at compile time (its macro has no
    /// non-float arm); C# spells it as a cached reflection check.
    /// Bool-carrying components stay on the packed per-entity paths (or
    /// model the flag as a float field and compare against 0).
    /// </summary>
    private static class ViewInfo<T> where T : unmanaged, IBatchComponent
    {
        public static readonly int Stride;
        public static readonly string? Error;

        static ViewInfo()
        {
            var fields = typeof(T).GetFields(
                System.Reflection.BindingFlags.Public |
                System.Reflection.BindingFlags.NonPublic |
                System.Reflection.BindingFlags.Instance);
            foreach (var f in fields)
            {
                if (f.FieldType != typeof(float))
                {
                    Error = $"labelle: batch view '{typeof(T).Name}' ({T.Name}) field " +
                        $"'{f.Name}' is {f.FieldType.Name} — batch views must be float-only " +
                        "structs (the rows are reinterpreted zero-copy over the f32 stream); " +
                        "keep bool/int-carrying components on the packed per-entity paths";
                    return;
                }
            }
            var size = System.Runtime.CompilerServices.Unsafe.SizeOf<T>();
            if (fields.Length == 0 || size != fields.Length * 4)
            {
                Error = $"labelle: batch view '{typeof(T).Name}' ({T.Name}) has " +
                    (fields.Length == 0
                        ? "no fields — a marker view has nothing to iterate; filter marker " +
                          "components through the raw BatchGet names instead"
                        : "padding the stream cannot back (sequential float fields only)");
                return;
            }
            Stride = size / 4;
        }
    }

    private static int ViewStride<T>() where T : unmanaged, IBatchComponent
    {
        if (ViewInfo<T>.Error is { } err) throw new BatchRefusedException(err);
        return ViewInfo<T>.Stride;
    }

    private static int BatchCore(string namesJson, int stride, BatchRowLoop loop)
    {
        if (_batchActive)
            throw new BatchRefusedException(
                "labelle: nested Batch calls are not supported (the shared stream buffer " +
                "would alias mid-iteration) — restructure into sequential batches");
        _batchActive = true;
        try
        {
            var buf = _batchBuf ??= new float[64];
            var count = BatchGet(namesJson, ref buf, out var floats);
            _batchBuf = buf;
            if (count == 0) return 0;
            if (floats != count * stride)
                throw new BatchRefusedException(
                    $"labelle: Batch({namesJson}): the typed views' stride ({stride} floats " +
                    $"per entity) does not match the host stream ({floats} floats / {count} " +
                    "entities) — a field the stream skips (non-scalar) disagrees with the " +
                    "view layout; use BatchGet/BatchSet with explicit offsets for these " +
                    "components");
            loop(buf.AsSpan(0, floats), stride, count);
            // An exception in the delegate unwinds PAST this line —
            // BatchSet never runs (abort); early exit falls through
            // (commit).
            BatchSet(namesJson, buf, floats);
            return count;
        }
        finally
        {
            _batchActive = false;
        }
    }
}
