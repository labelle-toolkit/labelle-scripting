// scripts/Json.cs — minimal flat-JSON field extraction shared by the game's
// scripts (contract payloads are small, flat JSON; a structured serializer is
// future work). Mirrors the rust example's byte walkers — no float ever
// touches an entity id (ulong end to end).

using System.Globalization;

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
            NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : fallback;
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
