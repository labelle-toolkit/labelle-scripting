# scripts/spawner.cr — the plain-script tier (crystal twin of
# rust-game's scripts/spawner.rs): seeds the world in `init` and
# commands a feeding over the engine bus on tick 2. State lives in
# instance vars — the native family's isolation is the type system
# itself (no per-script receiver tricks: two scripts are two classes).
#
# Each observable milestone logs ONE `CRYSTAL_<TOKEN>` line so CI can
# `grep -oE '(CRYSTAL|ZIG)_[A-Z0-9_.]+'` and diff the exact ordered
# sequence. This script's slice of the 5-frame timeline
# (scripts/game.cr's header documents the full interleaving):
#
#   setup   CRYSTAL_INIT              init: Worker entity created,
#                                      Hunger{level: 0.875} written
#   tick 2  CRYSTAL_FEED_SENT         emit hunger__feed{entity, amount: 0.5}
#                                      (updates run in registration order —
#                                      spawner first — so this precedes tick
#                                      2's CRYSTAL_LEVEL_* token; the emit
#                                      reaches TWO subscribers off one bus:
#                                      the native hooks/feed_watcher.zig at
#                                      this frame's dispatchEvents, the
#                                      crystal handler on tick 3's inbox)
#   tick 3  CRYSTAL_ENGINE_TICK_SEEN  first engine__tick arrives (emitted by
#                                      g.tick AFTER the tick-1 drain, drained
#                                      at tick 2's boundary, inbox-dispatched
#                                      at tick 3 start)
#   deinit  CRYSTAL_DEINIT            shutdown reached the spawner's deinit
#                                      (reverse registration order — after
#                                      the hunger system's CRYSTAL_CTRL_DONE)

class Spawner < Labelle::Script
  @worker : Labelle::EntityId = 0_u64
  @tick = 0_u32
  @engine_tick_seen = false

  def init : Nil
    # The worker the HungerSystem manages. 0.875 (7/8, exact in binary
    # floating point at every width en route) seeds the decay chain; the
    # component's declared default is 1.0, so the read-back chain
    # starting at 0.875 proves THIS write traveled through the real ECS.
    @worker = Labelle.create_entity
    Labelle.set_component(@worker, "Hunger", %({"level":0.875,"starving":false}))
    Labelle.set_component(@worker, "Worker", "{}")

    # Builtin-event consumption: an ENGINE event that fires every frame
    # in any game shape — proving the engine's own bus reaches crystal
    # handlers through the tap. Logged once in on_event; the frame
    # number rides OUTSIDE the token so the pinned sequence stays
    # stable.
    Labelle.subscribe("engine__tick")

    # Ids are UInt64 END TO END in crystal — no bitcast (lua/ruby) or
    # BigInt (typescript) caveat; interpolation prints the true
    # unsigned id.
    Labelle.log("CRYSTAL_INIT id=#{@worker}")
  end

  def on_event(name : String, payload : String) : Nil
    if name == "engine__tick" && !@engine_tick_seen
      @engine_tick_seen = true
      frame = Game.u64_field(payload.to_slice, %("frame_number":)) || 0_u64
      Labelle.log("CRYSTAL_ENGINE_TICK_SEEN frame=#{frame}")
    end
  end

  def update(dt : Float32) : Nil
    @tick += 1

    # Command-as-event, CROSS-SCRIPT: this plain script commands the
    # HungerSystem (which subscribed in its init) to feed the worker.
    # The id and the exact f32 0.5 amount round-trip
    # events/hunger__feed.zig on the real engine bus; the handler sees
    # them on tick 3's inbox.
    if @tick == 2
      if Labelle.emit("hunger__feed", %({"entity":#{@worker},"amount":0.5}))
        Labelle.log("CRYSTAL_FEED_SENT")
      else
        Labelle.log("CRYSTAL_FEED_EMIT_FAIL")
      end
    end
  end

  def deinit : Nil
    Labelle.log("CRYSTAL_DEINIT")
  end
end
