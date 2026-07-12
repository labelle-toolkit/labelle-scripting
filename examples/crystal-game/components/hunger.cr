# The engine-side component the crystal scripts address by name over the
# Script Runtime Contract (`Labelle.get_component_into(id, "Hunger", …)` in
# scripts/hunger.cr). Since labelle-engine#775 / assembler v0.88.0 the crystal
# NATIVE family declares too (rust's twin): this is a GAME-SHAPED
# `components/*.cr` declaration — bare `Labelle.component` with NO `require`
# line (the tool injects `require "./labelle"`) and its declare tool
# `labelle-declare-crystal` extracts the schema into the generated
# scripting_components.zig. It is NOT embedded or compiled into the game — only
# its schema travels — so the component registers by name and every contract
# call resolves against it at runtime, exactly as the former
# components/hunger.zig did.
#
# The default is deliberately NOT the 0.875 the spawner writes: the decay chain
# starting at 0.875 proves the crystal-side write traveled, not the declared
# default.
Labelle.component "Hunger", {
  level:    {f32, 1.0},
  starving: {bool, false},
}
