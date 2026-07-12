# components/hunger.rb — the component DECLARED IN RUBY, beside the
# zero-field tag spelling (components/worker.rb): labelle-engine#237's
# second convention refinement, live since labelle-assembler v0.86.0
# (DECLARE_RUNNERS) + labelle-scripting v0.9.0 (tools/declare-ruby).
# The components/ dir is extension-keyed and mixed-language BY DESIGN —
# declaration files live where their kind lives, not in a scripts
# corner (this game has no Zig component left, but a .zig would sit
# right here beside these).
#
# ONE line, two consumers:
#
#   - at `labelle generate` the declare phase builds this repo's ruby
#     extractor (`zig build labelle-declare-ruby`), runs it over this
#     file, and codegens a REAL Zig registry component from the schema
#     (.labelle/<target>/scripting_components.zig — `pub const Hunger`
#     with `level: f32 = 0.875, starving: bool = false`): scenes, save
#     buckets, typed queries, events/hunger__feed.rb's consumers and
#     the contract's by-name dispatch all reach it exactly like the
#     components/hunger.zig file it replaces (CI greps the generated
#     file);
#
#   - at RUNTIME this file is embedded and registered BEFORE every
#     scripts/ entry (components-first registration order — CI pins
#     it), so this same line evaluates to a Component.ref-EQUIVALENT
#     view class and the `Hunger` constant already exists when
#     scripts/20_hunger_controller.rb loads — the controller carries no
#     Component.ref line anymore.
#
# The declared default level 0.875 (7/8 — exact in binary floating
# point at every width en route) IS the decay chain's seed: the spawner
# attaches the component BARE (`set("Hunger")` — the contract's
# all-defaults `{}` write), so tick 1's RUBY_LEVEL_0.625 = 0.875 - 0.25
# is reachable only through THIS declaration having traveled
# schema -> codegen -> registry -> ECS. The transcript proves the
# declaration by value; no extra token needed.
Hunger = Labelle.component "Hunger", level: 0.875, starving: false
