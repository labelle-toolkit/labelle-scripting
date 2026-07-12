# Test-crate entry: recomposes the SHIPPED sources around the suite's
# game module. `labelle` and `glue` are the exact files the plugin ships
# (native-crystal/src/ — required by relative path, not copied, so the
# code under test can never drift from the code that ships); `game` is
# the suite's scenario scripts, standing where the assembler stages a
# real game's `crystal/` dir. This is possible because the shipped
# main.cr composes the three requires at ITS root and glue reaches the
# game via the `Game` module name — the same recomposition seam the
# assembler staging uses (crystal's spelling of tests/rust/src/lib.rs's
# #[path] trick).

require "../../native-crystal/src/labelle"
require "../../native-crystal/src/glue"
require "./game/game"
