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
}
