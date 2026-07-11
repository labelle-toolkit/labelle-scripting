# spawner.rb — the plain top-level-hooks tier (init/update/deinit): seeds
# the world and commands a feeding over the engine bus. State lives in
# @ivars on the script's private receiver; the `engine__tick`
# subscription happens in `init` so the block captures that receiver (a
# file-scope block would capture `main` instead — its @ivars are not the
# hooks').
#
# Each observable milestone logs ONE `RUBY_<TOKEN>` line so CI can
# `grep -oE 'RUBY_[A-Z0-9_.]+'` and diff the exact ordered sequence.
# This script's slice of the 5-frame timeline (LABELLE_NULL_FRAMES=5;
# hunger_controller.rb documents the full interleaving):
#
#   setup   RUBY_INIT              init(): Worker entity created,
#                                   Hunger{level: 0.875} written
#   tick 2  RUBY_FEED_SENT         emit hunger__feed{entity, amount: 0.5}
#                                   (script updates run BEFORE controller
#                                   ticks, so this precedes tick 2's
#                                   RUBY_LEVEL_* token)
#   tick 3  RUBY_ENGINE_TICK_SEEN  first engine__tick arrives (emitted by
#                                   g.tick AFTER the tick-1 drain, drained
#                                   at tick 2's boundary, inbox-dispatched
#                                   at tick 3 start)
#   deinit  RUBY_DEINIT            shutdown reached the per-script deinit
#                                   (after controller teardowns)
#
# Why the one-frame latencies: subscriptions activate at drain boundaries
# (no same-tick replay) and handlers run on the NEXT tick's inbox
# dispatch — see labelle-engine/src/script_contract.zig "Event tap
# semantics".

def init
  @tick = 0
  @engine_tick_seen = false

  # The worker the HungerController manages. 0.875 (7/8, exact in binary
  # floating point at every width en route) seeds the decay chain; the
  # component's declared default is 1.0, so the read-back chain starting
  # at 0.875 proves THIS write traveled through the real ECS.
  @worker = Labelle::Entity.create
  @worker.set("Hunger", level: 0.875, starving: false)
  @worker.set("Worker")

  # Builtin-event consumption: an ENGINE event that fires every frame in
  # any game shape — proving the engine's own bus reaches ruby handlers
  # through the tap. Logged once; the frame number rides OUTSIDE the
  # token so the pinned sequence stays stable.
  Labelle.on("engine__tick") do |ev|
    unless @engine_tick_seen
      @engine_tick_seen = true
      Labelle.log("RUBY_ENGINE_TICK_SEEN frame=#{ev[:frame_number]}")
    end
  end

  Labelle.log("RUBY_INIT id=#{Labelle.u64str(@worker.id)}")
end

def update(dt)
  @tick += 1

  # Command-as-event, CROSS-SCRIPT: this plain-hooks script commands the
  # controller (which subscribed in its setup) to feed the worker. The
  # id and the exact f32 0.5 amount round-trip events/hunger__feed.zig
  # on the real engine bus; the handler sees them on tick 3's inbox.
  if @tick == 2
    if Labelle.emit("hunger__feed", entity: @worker.id, amount: 0.5)
      Labelle.log("RUBY_FEED_SENT")
    else
      Labelle.log("RUBY_FEED_EMIT_FAIL")
    end
  end
end

def deinit
  Labelle.log("RUBY_DEINIT")
end
