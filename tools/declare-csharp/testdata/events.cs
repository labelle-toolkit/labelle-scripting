// Game-shaped C# event declarations for the labelle-declare-csharp byte-parity
// pin (tests/declare_csharp_tool.zig). No `using` line — the declare surface is
// global (a green run proves the tool needs no prelude injection). The
// declarations below are the golden's `csharp_events_source` verbatim
// (declare_cross_golden.zig).
[LabelleEvent]
record hunger__feed
{
    public ulong entity = 0;
    public double amount = 0.5;
    public bool urgent = false;
    public string reason = "why \"now\"";
    public Vec2 at = new(-1.5, 3.0);
}

[LabelleEvent]
record wave__spawned;
