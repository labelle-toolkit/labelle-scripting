# A GAME-SHAPED event declaration file for the cross-runner byte-parity test
# (labelle-engine#775): bare `Labelle.event "…"`, NO `require` line — what a
# real game events/*.cr writes; the tool injects the prelude. The assembler
# passes components/*.cr before events/*.cr, so this file is argv index 1
# (staged decl_0001.cr) and its events register after the component file's —
# matching emit_schema's per-kind insertion order. Kept byte-in-sync with
# tests/declare_cross_golden.zig's `crystal_events_source`.
Labelle.event "hunger__feed", {
  entity: {u64, 0},
  amount: {f32, 0.5},
  urgent: {bool, false},
  reason: {str, "why \"now\""},
  at:     {vec2, {-1.5, 3.0}},
}

Labelle.event "wave__spawned"
