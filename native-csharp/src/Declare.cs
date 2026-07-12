// The C# DECLARE surface — the schema-declaration DSL a csharp game uses to
// author components + events, and the reflection emitter that turns them into
// the cross-runner schema JSON (labelle-scripting#27, labelle-engine#743/#774;
// RFC-LANGUAGE-PLUGINS §4/§7). rust's native/src/labelle.rs `component!`/`event!`
// macros and crystal's native-crystal/src/labelle.cr macros are the twins.
//
// ## The declaration form
//
// A component (or event) is a `record` carrying `[LabelleComponent]` (or
// `[LabelleEvent]`), whose PUBLIC INSTANCE FIELDS are the schema fields and
// whose field INITIALIZERS are the declared defaults:
//
//     [LabelleComponent]
//     record Hunger
//     {
//         public double level = 0.875;
//         public bool starving = false;
//     }
//
//     [LabelleComponent(Persist.Transient)]
//     record Dead;
//
//     [LabelleEvent]
//     record hunger__feed
//     {
//         public ulong entity = 0;   // an entity-id field
//         public double amount = 0.5;
//     }
//
// The record's TYPE NAME is the component/event name (so an event is spelled
// `record hunger__feed`, a lowercase-underscore type name — legal C#, and these
// records are DECLARE-ONLY: they never back a runtime type in the game assembly,
// exactly like crystal's declare-only spelling). The FIELD NAME is used verbatim
// as the schema field name — consistent with every other language (rust/crystal/
// ts/lua/ruby all spell the schema field name directly; no case conversion).
//
// Field initializers (not primary-constructor parameters) are the declaration
// vehicle because C# restricts a record's primary-ctor defaults to compile-time
// CONSTANTS — which cannot express a `Vec2(-0.5, 7.0)` default. A field
// initializer can, so `[LabelleComponent] record …` with a `{ … }` body of
// public fields is THE C# form (this is C#'s honest deviation from the RFC's
// illustrative positional `record Hunger(float Level, …)`, the sibling of
// crystal's declare-only note).
//
// ## The type vocabulary (schema types: f32 / i32 / bool / str / vec2 / u64)
//
//   double | float → "f32"   int → "i32"   bool → "bool"
//   string → "str"   Vec2 → "vec2"   ulong → "u64" (the entity-id type)
//
// A float default is declared `double` so its AS-WRITTEN decimal formats at full
// f64 precision (the schema stores it as f32; matching rust's "bind the default
// to f64, do not narrow before %.14g" — an f32-narrowed `1e-05` would print its
// 14-significant-digit expansion, not "1e-05"). `float` is also accepted for
// exact defaults.
//
// ## Emission
//
// `LabelleDeclare.EmitSchema()` reflects the executing assembly (the declare
// PROBE the labelle-declare-csharp tool stages + compiles) for the attributed
// records and prints ONE schema JSON line, byte-identical to the lua/ruby/rust/
// crystal/ts runners' — one schema contract, N runners. This file ships in the
// plugin's native-csharp/ module (the dev-`.csproj` references it for IntelliSense
// and the game publish compiles it harmlessly — its types are unused at runtime);
// tools/declare-csharp/extract.zig `@embedFile`s it so the tool carries the exact
// surface it was built against. Never called at game runtime.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Reflection;
using System.Text;

/// <summary>Persistence policy for a declared component (a component is
/// "persistent" unless declared <see cref="Transient"/>); events are never
/// saved and carry no persistence.</summary>
public enum Persist { Persistent, Transient }

/// <summary>Marks a record as a Labelle component declaration. Its public
/// instance fields are the component's fields; each field initializer is the
/// declared default.</summary>
[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class LabelleComponentAttribute : Attribute
{
    /// <summary>Save policy — <see cref="Persist.Persistent"/> by default.</summary>
    public Persist Persist { get; }
    public LabelleComponentAttribute(Persist persist = Persist.Persistent) => Persist = persist;
}

/// <summary>Marks a record as a Labelle game-event declaration.</summary>
[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class LabelleEventAttribute : Attribute
{
    public LabelleEventAttribute() { }
}

/// <summary>A 2D vector field (schema type "vec2"). The engine stores each axis
/// as f32, so the constructor narrows — matching every other language's vec2
/// default emission (`vec2` defaults format from the narrowed value).</summary>
public readonly struct Vec2
{
    public readonly float X;
    public readonly float Y;
    public Vec2(double x, double y) { X = (float)x; Y = (float)y; }
}

/// <summary>The declare-mode schema emitter. Reflects the compiled probe
/// assembly for <see cref="LabelleComponentAttribute"/> / <see
/// cref="LabelleEventAttribute"/> records and returns the cross-runner schema
/// JSON (one compact line, no trailing newline). Never called at game
/// runtime.</summary>
public static class LabelleDeclare
{
    /// <summary>Emit the schema JSON for every attributed record in the
    /// executing assembly, byte-identical to the lua/ruby/rust/crystal/ts
    /// runners.</summary>
    public static string EmitSchema()
    {
        var asm = Assembly.GetExecutingAssembly();
        var comps = new List<Type>();
        var events = new List<Type>();
        foreach (var t in asm.GetTypes())
        {
            if (t.GetCustomAttribute<LabelleComponentAttribute>() is not null) comps.Add(t);
            else if (t.GetCustomAttribute<LabelleEventAttribute>() is not null) events.Add(t);
        }
        // Declaration order per kind = source order, recovered via the TypeDef
        // metadata token: the probe csproj lists the declaration files as
        // explicit, ORDERED <Compile> items (components/*.cs before events/*.cs,
        // argv order), so Roslyn emits TypeDefs in file order then source order
        // within a file — components-then-events, declaration order, falls out.
        comps.Sort((a, b) => a.MetadataToken.CompareTo(b.MetadataToken));
        events.Sort((a, b) => a.MetadataToken.CompareTo(b.MetadataToken));

        var sb = new StringBuilder();
        sb.Append("{\"components\":[");
        for (int i = 0; i < comps.Count; i++)
        {
            if (i > 0) sb.Append(',');
            ComponentFragment(sb, comps[i]);
        }
        sb.Append(']');
        if (events.Count > 0)
        {
            sb.Append(",\"events\":[");
            for (int i = 0; i < events.Count; i++)
            {
                if (i > 0) sb.Append(',');
                EventFragment(sb, events[i]);
            }
            sb.Append(']');
        }
        sb.Append('}');
        return sb.ToString();
    }

    private static void ComponentFragment(StringBuilder sb, Type t)
    {
        var persist = t.GetCustomAttribute<LabelleComponentAttribute>()!.Persist;
        sb.Append("{\"name\":");
        Quote(sb, t.Name);
        sb.Append(",\"persist\":\"");
        sb.Append(persist == Persist.Transient ? "transient" : "persistent");
        sb.Append("\",\"fields\":[");
        Fields(sb, t);
        sb.Append("]}");
    }

    private static void EventFragment(StringBuilder sb, Type t)
    {
        sb.Append("{\"name\":");
        Quote(sb, t.Name);
        sb.Append(",\"fields\":[");
        Fields(sb, t);
        sb.Append("]}");
    }

    private static void Fields(StringBuilder sb, Type t)
    {
        var instance = Activator.CreateInstance(t)!;
        var fields = t.GetFields(BindingFlags.Public | BindingFlags.Instance);
        // Fields alphabetized by name (ordinal — Rust str Ord's twin), the
        // shared cross-runner rule.
        Array.Sort(fields, (a, b) => string.CompareOrdinal(a.Name, b.Name));
        for (int i = 0; i < fields.Length; i++)
        {
            if (i > 0) sb.Append(',');
            var f = fields[i];
            sb.Append("{\"name\":");
            Quote(sb, f.Name);
            sb.Append(",\"type\":\"");
            sb.Append(SchemaType(f.FieldType, f.Name, t.Name));
            sb.Append("\",\"default\":");
            AppendDefault(sb, f.FieldType, f.GetValue(instance)!, f.Name, t.Name);
            sb.Append('}');
        }
    }

    private static string SchemaType(Type ft, string field, string decl)
    {
        if (ft == typeof(double) || ft == typeof(float)) return "f32";
        if (ft == typeof(int)) return "i32";
        if (ft == typeof(bool)) return "bool";
        if (ft == typeof(string)) return "str";
        if (ft == typeof(Vec2)) return "vec2";
        if (ft == typeof(ulong)) return "u64";
        throw new NotSupportedException(
            $"labelle-declare-csharp: field '{field}' of '{decl}' has unsupported type {ft.Name} " +
            "(allowed: double/float→f32, int→i32, bool, string→str, Vec2→vec2, ulong→u64)");
    }

    private static void AppendDefault(StringBuilder sb, Type ft, object v, string field, string decl)
    {
        if (ft == typeof(double) || ft == typeof(float))
            sb.Append(FmtF32(Convert.ToDouble(v, CultureInfo.InvariantCulture)));
        else if (ft == typeof(int))
            sb.Append(((int)v).ToString(CultureInfo.InvariantCulture));
        else if (ft == typeof(bool))
            sb.Append((bool)v ? "true" : "false");
        else if (ft == typeof(string))
            Quote(sb, (string)v);
        else if (ft == typeof(Vec2))
        {
            var vec = (Vec2)v;
            sb.Append("{\"x\":");
            sb.Append(G14(vec.X));
            sb.Append(",\"y\":");
            sb.Append(G14(vec.Y));
            sb.Append('}');
        }
        else if (ft == typeof(ulong))
            sb.Append(((ulong)v).ToString(CultureInfo.InvariantCulture));
        else
            throw new NotSupportedException(
                $"labelle-declare-csharp: field '{field}' of '{decl}' has unsupported type {ft.Name}");
    }

    // ── %.14g, byte-identical to C's printf (the rust g14 port) ─────────────
    // The lua declare tool formats floats through host libc `printf %.14g`; the
    // cross-runner golden proves the ruby/rust/crystal/ts emitters agree with it
    // byte-for-byte. We reproduce C's `%g` with precision 14: 14 significant
    // digits, %e vs %f chosen by exponent, trailing zeros stripped, exponent
    // >= 2 digits with sign. Formatting the default from the AS-WRITTEN f64
    // (never a narrowed f32) is why "1e-05" stays "1e-05".

    /// <summary>`%.14g` of a finite double, byte-identical to C's printf.</summary>
    private static string G14(double v)
    {
        if (v == 0.0) return "0"; // our declared values are never -0.0
        bool neg = v < 0.0;
        double a = Math.Abs(v);
        // Scientific with 13 fractional digits => 14 significant digits, rounded
        // at the 14th digit exactly as C rounds it.
        string sci = a.ToString("E13", CultureInfo.InvariantCulture);
        int ePos = sci.IndexOf('E');
        string mant = sci.Substring(0, ePos);
        int x = int.Parse(sci.Substring(ePos + 1), CultureInfo.InvariantCulture);
        string outStr;
        if (x < -4 || x >= 14)
        {
            string m = StripTrailingZeros(mant);
            char sign = x < 0 ? '-' : '+';
            outStr = m + "e" + sign + Math.Abs(x).ToString("D2", CultureInfo.InvariantCulture);
        }
        else
        {
            int frac = Math.Max(13 - x, 0);
            outStr = StripTrailingZeros(a.ToString("F" + frac.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture));
        }
        return neg ? "-" + outStr : outStr;
    }

    private static string StripTrailingZeros(string s)
    {
        if (!s.Contains('.')) return s;
        return s.TrimEnd('0').TrimEnd('.');
    }

    /// <summary>f32 default JSON: %.14g, then FORCE floatness ("1" → "1.0") so
    /// the schema reads unambiguously — the lua/ruby number rule. vec2 axes use
    /// raw <see cref="G14"/> (no floatness force), so "7.0" stays "7".</summary>
    private static string FmtF32(double v)
    {
        string s = G14(v);
        if (s.IndexOf('.') < 0 && s.IndexOf('e') < 0 && s.IndexOf('E') < 0) s += ".0";
        return s;
    }

    /// <summary>JSON string escaping, byte-for-byte the lua `quote()` / ruby
    /// `__quote`: named escapes for " \ \b \f \n \r \t; \u%04x for other control
    /// bytes (&lt;0x20 and 0x7f); every other byte passes through raw.</summary>
    private static void Quote(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            switch (b)
            {
                case (byte)'"': sb.Append("\\\""); break;
                case (byte)'\\': sb.Append("\\\\"); break;
                case 0x08: sb.Append("\\b"); break;
                case 0x0c: sb.Append("\\f"); break;
                case (byte)'\n': sb.Append("\\n"); break;
                case (byte)'\r': sb.Append("\\r"); break;
                case (byte)'\t': sb.Append("\\t"); break;
                default:
                    if (b < 0x20 || b == 0x7f)
                        sb.Append("\\u").Append(((int)b).ToString("x4", CultureInfo.InvariantCulture));
                    else
                        sb.Append((char)b);
                    break;
            }
        }
        sb.Append('"');
    }
}
