// The plugin glue: the [UnmanagedCallersOnly] entry points labelle-scripting's
// `csharp` arm (src/csharp/vm.zig) resolves through hostfxr and drives, plus
// the script registry + dispatch loops behind them. Games never touch this
// file — their surface is `Labelle` (Script, Scripts, the wrappers) plus the
// one `Game.Register` convention in their `csharp/Game.cs`.
//
// ## The cs entry convention (csharp glue ABI v1)
//
// src/csharp/vm.zig resolves these by name (load_assembly_and_get_function_pointer
// against `Labelle.Glue` with UNMANAGEDCALLERSONLY_METHOD) and calls, in
// Controller order:
//
// | entry          | when                                                    |
// |----------------|---------------------------------------------------------|
// | AbiVersion     | Vm.init — handshake, must return CS_ABI_VERSION          |
// | Setup          | end of Controller.setup — runs Game.Register, then every |
// |                | script's Init (throwing inits are EVICTED)               |
// | DispatchInbox  | top of Controller.tick — drains the inbox, fans out      |
// |                | each entry to every live script's OnEvent                |
// | Tick           | Controller.tick — every Update(dt)                       |
// | Deinit         | Controller.deinit — every Deinit (reverse order), then   |
// |                | the registry is dropped                                  |
//
// Bump CS_ABI_VERSION on any change to this table's names or signatures — the
// Zig arm refuses a mismatched glue at boot (the stale-assembly case: a plugin
// upgrade with a stale build-cache DLL must fail the handshake, not corrupt a
// tick).
//
// ## Exceptions MUST NOT unwind across the FFI boundary
//
// Every entry wraps its whole body in try/catch, and every script hook call is
// ADDITIONALLY caught one script at a time, so one throwing script cannot
// starve its siblings. A managed exception unwinding out of an
// [UnmanagedCallersOnly] method into the host's foreign frames is UNDEFINED
// BEHAVIOR — the double catch is the difference between "one script logged an
// error" and "the game died". Semantics mirror the rust/crystal glue exactly:
// Init throw → logged + evicted; Update/OnEvent throw → logged every time,
// script stays; Deinit throw → logged, teardown continues; Game.Register throw
// → logged, ALL registrations dropped (all-or-nothing — a half-registered set
// would run hooks the author never ordered).
//
// The registry is static state on the main thread (the contract is
// main-thread-only; every entry point runs on the game's main thread).

using System.Runtime.InteropServices;

// Global namespace (see Labelle.cs) — the Zig arm resolves this type as
// "Glue, labelle_csharp_scripts".

/// <summary>Plugin-internal, not game surface.</summary>
public static class Glue
{
    /// <summary>The glue ABI revision <see cref="AbiVersion"/> reports and the Zig
    /// arm's SUPPORTED_CS_ABI_VERSION must equal.</summary>
    private const uint CS_ABI_VERSION = 1;

    private sealed class Entry
    {
        public required string Name;
        public required Script Script;
        // Cleared when Init throws: an evicted script never receives
        // OnEvent/Update/Deinit (half-initialized state must not run).
        public bool Alive = true;
    }

    private static readonly List<Entry> Entries = new();

    // False until a setup succeeds and after deinit — the tick legs no-op
    // without a registry, mirroring rust's Option<Registry>.
    private static bool HasRegistry;

    // Reused drain buffer for PollInto — grown at most to the workload's
    // high-water mark, so the steady state polls with no buffer growth
    // (each drained entry still allocates the immutable strings handed to
    // OnEvent; that is C#'s string contract).
    private static byte[] _inbox = Array.Empty<byte>();

    /// <summary>One line per throw, type + message, never throwing itself (it runs
    /// inside catch handlers — a throw here would escape the FFI gate).</summary>
    private static void LogThrow(string context, Exception ex)
    {
        try
        {
            Labelle.Log($"csharp: {context} threw: {ex.GetType().Name}: {ex.Message}");
        }
        catch
        {
            // Last-ditch: even logging failed; swallow rather than unwind.
        }
    }

    // ── Entry points (the Zig arm resolves + calls these) ─────────────────

    /// <summary>Handshake: the glue ABI revision this assembly was built against.</summary>
    [UnmanagedCallersOnly]
    public static uint AbiVersion() => CS_ABI_VERSION;

    /// <summary>Build the registry (Game.Register), then run every script's Init — a
    /// throwing Init logs and EVICTS that script; the rest keep going.
    /// Idempotent-by-rebuild: a re-setup drops the old registry and registers from
    /// scratch. Returns 0, or -1 when Game.Register itself threw (no scripts).</summary>
    [UnmanagedCallersOnly]
    public static int Setup()
    {
        try
        {
            Entries.Clear();
            HasRegistry = false;

            var scripts = new Scripts();
            try
            {
                Game.Register(scripts);
            }
            catch (Exception ex)
            {
                // All-or-nothing registration: drop whatever registered
                // before the throw — a partial set would run hooks the
                // author never finished ordering.
                LogThrow("Register()", ex);
                Labelle.Log("csharp: no scripts registered");
                return -1;
            }

            foreach (var (name, script) in scripts.Entries)
                Entries.Add(new Entry { Name = name, Script = script });
            HasRegistry = true;

            foreach (var entry in Entries)
            {
                try
                {
                    entry.Script.Init();
                }
                catch (Exception ex)
                {
                    LogThrow($"script '{entry.Name}' in Init", ex);
                    entry.Alive = false;
                    Labelle.Log($"csharp: script evicted: '{entry.Name}'");
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            LogThrow("Setup", ex);
            return -1;
        }
    }

    /// <summary>Drain the event inbox (FIFO, one poll loop) and fan each entry out to
    /// every live script's OnEvent. Handler throws are contained per script per event;
    /// the drain always completes.</summary>
    [UnmanagedCallersOnly]
    public static void DispatchInbox()
    {
        try
        {
            if (!HasRegistry) return;
            int n;
            while ((n = Labelle.PollInto(ref _inbox)) > 0)
            {
                // Entries are "<name> <json>"; an entry is never empty.
                var text = System.Text.Encoding.UTF8.GetString(_inbox, 0, n);
                var sp = text.IndexOf(' ');
                var name = sp < 0 ? text : text[..sp];
                var payload = sp < 0 ? "" : text[(sp + 1)..];
                foreach (var entry in Entries)
                {
                    if (!entry.Alive) continue;
                    try
                    {
                        entry.Script.OnEvent(name, payload);
                    }
                    catch (Exception ex)
                    {
                        LogThrow($"script '{entry.Name}' in OnEvent('{name}')", ex);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            LogThrow("DispatchInbox", ex);
        }
    }

    /// <summary>Every live script's Update(dt), registration order. A throwing Update
    /// is logged EVERY tick and the script stays registered (its state is intact);
    /// siblings always run.</summary>
    [UnmanagedCallersOnly]
    public static void Tick(float dt)
    {
        try
        {
            if (!HasRegistry) return;
            foreach (var entry in Entries)
            {
                if (!entry.Alive) continue;
                try
                {
                    entry.Script.Update(dt);
                }
                catch (Exception ex)
                {
                    LogThrow($"script '{entry.Name}' in Update", ex);
                }
            }
        }
        catch (Exception ex)
        {
            LogThrow("Tick", ex);
        }
    }

    /// <summary>Every live script's Deinit, REVERSE registration order (teardown is
    /// LIFO against setup), then the registry is dropped. Throws are contained per
    /// script; teardown always completes. Idempotent.</summary>
    [UnmanagedCallersOnly]
    public static void Deinit()
    {
        try
        {
            if (!HasRegistry) return;
            HasRegistry = false;
            // Snapshot + clear BEFORE hooks run: a Deinit that somehow
            // re-enters an entry point sees "no registry" (a no-op).
            var entries = Entries.ToArray();
            Entries.Clear();
            for (int i = entries.Length - 1; i >= 0; i--)
            {
                var entry = entries[i];
                if (!entry.Alive) continue;
                try
                {
                    entry.Script.Deinit();
                }
                catch (Exception ex)
                {
                    LogThrow($"script '{entry.Name}' in Deinit", ex);
                }
            }
        }
        catch (Exception ex)
        {
            LogThrow("Deinit", ex);
        }
    }
}
