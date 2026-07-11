# The suite's game module — what a real game's `crystal/game.cr` is to
# the shipped sources. One extra, TEST-ONLY seam: because
# `Game.register` runs afresh on every `Controller.setup` (the glue
# rebuilds the registry from scratch), each Zig test picks its scenario
# BEFORE setup and `register` PULLS it here through a suite-exported
# host symbol (`labelle_cr_test_scenario`, tests/crystal_suite.zig) —
# the crystal analog of tests/rust/game/mod.rs's selector, with the
# direction deliberately inverted: crystal-side state (a class var)
# would be RE-INITIALIZED by the runtime boot's top-level pass, wiping
# any selection made before the first setup, and calling INTO crystal
# before boot is exactly the hazard the plugin's boot ordering exists
# to prevent. Pulling host state at register time (always post-boot)
# has neither problem. An empty / unknown selection registers nothing
# (a scriptless game).
#
# It also demonstrates the point of the native family: game modules are
# full crystal — they can declare their own `lib` externs against host
# symbols, define classes, share helpers — while the `Labelle` module
# keeps the world access safe.

require "./util"
require "./behavior"
require "./counter"
require "./raises"
require "./big_id"
require "./big_query"
require "./events"
require "./lifecycle"
require "./gc_churn"

# Test-only host symbol (exported by tests/crystal_suite.zig): copies
# the selected scenario name into `out_buf`, returns its length.
lib LibSuite
  fun labelle_cr_test_scenario(out_buf : UInt8*, cap : LibC::SizeT) : LibC::SizeT
end

module Game
  # The game registration convention (see native-crystal/src/game/game.cr
  # for the shape a real game implements). Registration order is hook
  # order.
  def self.register(scripts : Labelle::Scripts) : Nil
    buf = uninitialized UInt8[64]
    len = LibSuite.labelle_cr_test_scenario(buf.to_unsafe, 64)
    scenario = String.new(buf.to_unsafe, len)
    case scenario
    when "behavior"
      scripts.add "behavior", Behavior.new
    when "errors"
      # Raising update between two healthy siblings: containment must
      # be per-script (the sibling AFTER the exploder still runs).
      scripts.add "counter", Counter.new
      scripts.add "exploder", Exploder.new
      scripts.add "counter_after", Counter.new
    when "bad_init"
      # Raising init: evicted before any update/deinit; sibling
      # registered AFTER it still initializes and runs.
      scripts.add "bad_init", BadInit.new
      scripts.add "counter", Counter.new
    when "register_raise"
      raise "register scenario raise"
    when "big_id"
      scripts.add "big_id", BigId.new
    when "big_query"
      scripts.add "big_query", BigQuery.new
    when "events"
      # Two subscriber instances: inbox fan-out must reach every live
      # script, not just the first.
      scripts.add "events_a", EventCounter.new("Seen")
      scripts.add "events_b", EventCounter.new("SeenB")
    when "lifecycle"
      scripts.add "lifecycle", Lifecycle.new
    when "gc_churn"
      scripts.add "gc_churn", GcChurn.new
    end
  end
end
