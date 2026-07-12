# components/worker.rb — the tag component, ruby-declared: the second
# leg of the `each("Hunger", "Worker")` query in
# scripts/20_hunger_controller.rb (the #742 HungerController shape).
# The explicit empty spec Hash is the zero-field TAG shape — a marker
# with no payload, good for set/has?/remove and query legs. The declare
# phase emits it into the generated registry beside Hunger (`pub const
# Worker`, a field-less struct, in scripting_components.zig — CI greps
# it), and at runtime the same line yields the zero-field view class.
#
# The spawner still attaches it BY NAME (`@worker.set("Worker")` — the
# all-defaults write): Entity#set takes a component name or a
# Component.ref INSTANCE, never the view class, and instantiating a
# zero-field view just to write a tag would be noise.
#
# This file used to be the example's "deliberately still Zig"
# mixed-language demo (components/worker.zig). It went ruby with
# labelle-engine#772's mandate — every shipped language must be able to
# go 100% selected-language — so the example's ONLY remaining .zig is
# the OPTIONAL native escape hatch, hooks/feed_watcher.zig (CI deletes
# it in a scratch copy and the game still runs green).
Worker = Labelle.component "Worker", {}
