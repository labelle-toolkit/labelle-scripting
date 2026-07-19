// A float-only component for the BATCHED fast path (contract v1.3,
// labelle-scripting#44): scripts/Swarm.cs drives three of these through
// `Labelle.Batch` — one contract crossing per direction per tick instead of
// a get/set per entity. Declared like components/Hunger.cs (schema-only; the
// script addresses it via its typed batch view at runtime). NOTE the
// field-name choice: script-declared components codegen with fields SORTED
// BY NAME, and the batch stream walks the generated struct's field order —
// x < y keeps the declared order and the stream order identical.
// `float` fields (not `double` like Hunger's): both spell schema "f32" —
// the declare vocabulary has no f64, and `double` exists only so
// non-exact DEFAULTS format at full precision before %.14g — but the
// batch views these fields back are `float`-typed, so `float` here keeps
// the declaration visibly aligned with the view (0.0 is exact either way).
[LabelleComponent]
record Boid
{
    public float x = 0.0f;
    public float y = 0.0f;
}
