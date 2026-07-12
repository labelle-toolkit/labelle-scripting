# A GAME-SHAPED component declaration file for the cross-runner byte-parity
# test (labelle-engine#775): bare `Labelle.component "…"` with NO `require`
# line — exactly what a real game components/*.cr writes. The tool injects the
# prelude (`require "./labelle"`), so if these declarations extract, the
# injection works. Kept byte-in-sync with tests/declare_cross_golden.zig's
# `crystal_components_source`.
Labelle.component "Kinematics", {
  speed:      {f32, 12.5},
  accel:      {f32, 1.0},
  tiny:       {f32, 1e-05},
  huge:       {f32, 3.4e38},
  jump_count: {i32, 3},
  min_i32:    {i32, -2147483648},
  max_i32:    {i32, 2147483647},
  grounded:   {bool, true},
  home:       {vec2, {-0.5, 7.0}},
  label:      {str, "he said \"hi\"\n\ttab\\done"},
  owner:      {u64, 0},
}

Labelle.component "Dead", persist: "transient"
