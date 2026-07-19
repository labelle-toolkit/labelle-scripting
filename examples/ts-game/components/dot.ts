// components/dot.ts — the all-float component behind the BATCHED tier
// (labelle-scripting#44): four f32 fields, no ints, so it is exactly the
// shape the batch stream carries (contract v1.3 refuses int-typed fields
// — their packed per-entity codec is lossless instead).
//
// Same one-line, two-consumer declaration as components/hunger.ts: at
// `labelle generate` the schema codegens a real registry component
// (`pub const Dot` in scripting_components.zig — CI greps it); at runtime
// the emitted .js registers before every scripts/ entry, so the ref
// exists when scripts/30_swarm.ts loads (the swarm addresses it by name
// string anyway — both spellings are equivalent).
export const Dot = labelle.component("Dot", { x: 0.0, y: 0.0, vx: 0.0, vy: 0.0 });
