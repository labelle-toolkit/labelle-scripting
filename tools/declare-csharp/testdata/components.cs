// Game-shaped C# component declarations for the labelle-declare-csharp byte-
// parity pin (tests/declare_csharp_tool.zig). The declare surface
// (`[LabelleComponent]`, `Vec2`, `Persist`) lives in the GLOBAL namespace, so a
// real game's components/*.cs — like this file — carry NO `using` line; a green
// run proves the tool needs no prelude injection. The declarations below are
// the golden's `csharp_components_source` verbatim (declare_cross_golden.zig).
[LabelleComponent]
record Kinematics
{
    public double speed = 12.5;
    public double accel = 1.0;
    public double tiny = 1e-05;
    public double huge = 3.4e38;
    public int jump_count = 3;
    public int min_i32 = -2147483648;
    public int max_i32 = 2147483647;
    public bool grounded = true;
    public Vec2 home = new(-0.5, 7.0);
    public string label = "he said \"hi\"\n\ttab\\done";
    public ulong owner = 0;
}

[LabelleComponent(Persist.Transient)]
record Dead;
