// A float-only component for the BATCHED fast path (contract v1.3,
// labelle-scripting#44): scripts/Swarm.cs drives three of these through
// `Labelle.Batch` — one contract crossing per direction per tick instead of
// a get/set per entity. Declared like components/Hunger.cs (schema-only; the
// script addresses it via its typed batch view at runtime). NOTE the
// field-name choice: script-declared components codegen with fields SORTED
// BY NAME, and the batch stream walks the generated struct's field order —
// x < y keeps the declared order and the stream order identical.
[LabelleComponent]
record Boid
{
    public double x = 0.0;
    public double y = 0.0;
}
