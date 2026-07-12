# scripts/feed_watcher.rb — the THIRD hunger__feed subscriber, and the
# ruby mirror of hooks/feed_watcher.zig: one `Labelle.emit` in
# scripts/10_spawner.rb (tick 2) now demonstrably reaches
#
#   - the ruby controller's `on("hunger__feed")` (feeds the worker),
#   - THIS pure-ruby watcher, and
#   - the native Zig hook (hooks/feed_watcher.zig),
#
# all off the same engine bus, no glue. The token carries the parsed
# payload amount (RUBY_WATCHER_SAW_0.5 — f32 0.5 is exact in binary
# floating point), so it proves the payload crossed intact, not just
# that a handler fired.
#
# Deliberately a TOP-LEVEL (file-scope) subscription — the third legal
# subscription site next to plain-hook `init` and controller `setup`.
# The README's caveat ("subscribe inside init, not at file scope")
# guards @ivars: a file-scope block captures `main`, not a script
# receiver. A stateless watcher touches no @ivars, so file scope is
# exactly right here — the handler exists from VM boot, before any
# init runs.
#
# No ordering prefix: unnumbered scripts register AFTER the numbered
# ones (10_spawner, 20_hunger_controller), alphabetically — this file
# demonstrates the two spellings coexisting in one scripts/ dir.
#
# Timeline slice (scripts/20_hunger_controller.rb has the full
# interleaving): the emit rides tick 2, ruby handlers run on tick 3's
# inbox dispatch — RUBY_WATCHER_SAW_0.5 lands on tick 3, BEFORE the
# controller's RUBY_FED_LEVEL_0.875 (per-event handlers run in
# SUBSCRIPTION order, and this file-scope sub happened at chunk load —
# before the controller's setup-time `on`), one tick after the native
# hook's ZIG_FEED_SEEN_0.5.
Labelle.on("hunger__feed") do |ev|
  Labelle.log("RUBY_WATCHER_SAW_#{ev[:amount]}")
end
