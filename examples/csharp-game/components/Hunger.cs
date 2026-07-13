// The engine-side component the C# scripts address by name over the Script
// Runtime Contract (`Labelle.GetComponentInto(id, "Hunger", …)` in
// scripts/HungerSystem.cs) — now DECLARED in C# (labelle-scripting#27): the
// `[LabelleComponent]` record's public fields are the schema, extracted at
// `labelle generate` by labelle-declare-csharp and codegen'd into the game's
// component registry exactly like a components/*.zig would be. No `using` — the
// declare surface (`[LabelleComponent]`, `Vec2`, …) is global (native-csharp/
// src/Declare.cs).
//
// The default is deliberately NOT the 0.875 the spawner writes: the decay chain
// starting at 0.875 proves the C#-side write traveled through the real ECS, not
// the declared default.
[LabelleComponent]
record Hunger
{
    public double level = 1.0;
    public bool starving = false;
}
