# A float-only component for the BATCHED fast path (contract v1.3,
# labelle-scripting#44): scripts/swarm.cr drives three of these through
# `Labelle.batch` — one contract crossing per direction per tick instead
# of a get/set per entity. Declared like components/hunger.cr
# (schema-only; the script addresses it by name / typed batch view at
# runtime). NOTE the field-name choice: script-declared components
# codegen with fields SORTED BY NAME, and the batch stream walks the
# generated struct's field order — x < y keeps the declared order and
# the stream order identical.
Labelle.component "Boid", {
  x: {f32, 0.0},
  y: {f32, 0.0},
}
