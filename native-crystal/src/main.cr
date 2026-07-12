# labelle_crystal_scripts — the build entry a crystal-scripted labelle
# game compiles its `crystal/` sources through (labelle-engine#741,
# native family; rust's `native/src/lib.rs` twin).
#
# Anatomy (three requires, deliberately composed HERE so the repo's own
# test entry can recompose the SAME shipped files around a different
# game module via relative requires — tests/crystal/main.cr):
#
#   labelle   — the Script Runtime Contract binding + the script API
#               (`Labelle::Script`, `Labelle::Scripts`, the wrappers).
#               The game's surface.
#   glue      — the `labelle_cr_*` entry points the plugin Controller
#               drives; owns the registry, the inbox drain, the runtime
#               boot and the raise containment. Not game-facing. It
#               reaches the game via the `Game` module name, resolved
#               from whatever this file requires — the same seam the
#               assembler staging swaps.
#   game/game — THE GAME'S `crystal/` DIR. This repo ships a
#               placeholder (empty `Game.register`); at `labelle
#               generate` the assembler stages the game's `crystal/`
#               sources over `src/game/`, so the game's `game.cr` is
#               the module root this require resolves to.
#
# Built by the plugin's declared steps (plugin.labelle
# `.language_builds`): `crystal build --cross-compile` emits
# `labelle_crystal_scripts.o` (which still carries crystal's `main` —
# no `--no-main` exists), then the localization step demotes every
# symbol except the `labelle_cr_*` entries, and the resulting object
# links into the game binary, where the `labelle_*` contract symbols it
# consumes resolve against the host's exports — same-binary, zero
# indirection, exactly like the Zig side's extern declarations.

require "./labelle"
require "./glue"
require "./game/game"
