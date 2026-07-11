# Placeholder game module — REPLACED AT GENERATE.
#
# In a consuming game, the assembler stages the project's `crystal/`
# dir over this directory (`src/game/`), so the game's `crystal/game.cr`
# is this file's real body — the module root `main.cr` requires. A game
# split across several files requires its siblings from here
# (`require "./player"`, or `require "./**"` to pull in the whole dir).
# The convention it must implement is exactly one entry point:
#
# ```
# module Game
#   def self.register(scripts : Labelle::Scripts)
#     scripts.add "player", Player.new
#   end
# end
# ```
#
# Two rules of the road (see glue.cr's boot doc): scripts are classes
# inheriting `Labelle::Script`, and no top-level statements with world
# side effects — the top level runs once at runtime BOOT, before any
# world exists.
#
# This placeholder keeps the shipped sources compiling standalone
# (`crystal build` against the plugin repo, and the repo's own test
# recomposition) — it registers nothing.

module Game
  # The game registration entry point. Replaced by the game's own
  # `crystal/game.cr` at generate; this placeholder registers no
  # scripts.
  def self.register(scripts : Labelle::Scripts) : Nil
  end
end
