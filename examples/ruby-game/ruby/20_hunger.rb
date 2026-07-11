# 20_hunger.rb — the structured tier: the labelle-engine#742 acceptance
# pattern, verbatim ergonomics, against the REAL engine —
#
#   - `Labelle::Component.ref` builds the Struct-backed view class,
#   - the controller caches ONE instance in setup (`@h = Hunger.new`),
#   - tick refills it per entity via `e.get(Hunger, into: @h)`, mutates
#     fields, writes back with `e.set(@h)`,
#   - command-as-event feeding (`hunger__feed`, events/hunger__feed.zig)
#     subscribed in setup — emitted here on tick 2, so the round-trip
#     over the engine bus is part of the pinned transcript,
#   - `Labelle::FrameArray` is the per-frame scratch (collect ids, then
#     process — mruby's Array#clear would FREE the backing every tick),
#   - plain hooks coexist: a top-level `init` seeds the worker.
#
# `Hunger` is a real engine component (components/hunger.zig) — ruby has
# no declare mode yet, so the ref resolves against it by name at runtime.
#
# Milestones on top of 10_ball.rb's (numbers seeded exact in binary
# floating point — 0.875, 0.125 — so the tokens derived from payload and
# threshold comparisons are deterministic):
#
#   setup   RUBY_WORKER_READY     top-level init seeded the worker
#           RUBY_CTRL_READY       controller setup ran (after ALL inits)
#   tick 2  RUBY_FEED_EMITTED     controller emits hunger__feed onto the bus
#   tick 3  RUBY_FED              handler round-tripped: entity id + exact
#                                  amount decoded, get-into + set applied
#   tick 4  RUBY_STARVING         decay crossed the threshold — the level
#                                  persisted through the real ECS across ticks
#   tick 5  RUBY_FRAME_ARRAY_FLAT warmed scratch never grew (growth_count 0)
#   deinit  RUBY_CTRL_DONE        teardown ran (before per-script deinits)

Hunger = Labelle::Component.ref("Hunger", :level, :starving)

def init
  w = Labelle::Entity.create
  w.set("Hunger", level: 0.875, starving: false)
  w.set("Worker")
  Labelle.log("RUBY_WORKER_READY id=#{Labelle.u64str(w.id)}")
end

class HungerController < Labelle::Controller
  DECAY = 12.0 # per second — 0.2/tick at the null backend's fixed 60 fps
  FEED_AMOUNT = 0.125

  def setup
    @h = Hunger.new # once, in setup — the cached view instance
    @fa = Labelle::FrameArray.new(8) # per-frame scratch, backing survives clear
    @tick = 0
    @was_starving = false
    on("hunger__feed") { |ev| feed(ev[:entity], ev[:amount] || 0.5) }
    log("RUBY_CTRL_READY")
  end

  def tick(dt)
    @tick += 1

    # The FrameArray idiom: clear keeps the backing, collect this tick's
    # ids, then process — stash e.id, never e (`each` reuses one wrapper).
    @fa.clear
    each("Hunger", "Worker") { |e| @fa << e.id }

    i = 0
    while i < @fa.size
      e = entity(@fa[i])
      e.get(Hunger, into: @h) # REFILLS the cached instance
      @h.level -= DECAY * dt
      @h.starving = @h.level <= 0.25
      e.set(@h) # instance knows its component; writes to THIS entity

      if @h.starving && !@was_starving
        @was_starving = true
        log("RUBY_STARVING")
      end

      # Command-as-event: on tick 2, ask for a feeding over the bus. The
      # handler above sees it on tick 3's inbox dispatch (drain-boundary
      # latency, same as lua) — the id and the exact amount round-trip
      # through events/hunger__feed.zig on the real engine bus.
      if @tick == 2
        emit("hunger__feed", entity: e.id, amount: FEED_AMOUNT)
        log("RUBY_FEED_EMITTED")
      end
      i += 1
    end

    if @tick == 5 && @fa.growth_count == 0 && @fa.size == 1
      log("RUBY_FRAME_ARRAY_FLAT")
    end
  end

  # Same-VM public API for other ruby code (the command handler above).
  def feed(id, amount)
    e = entity(id)
    unless e.get(Hunger, into: @h)
      log("RUBY_FEED_TARGET_MISSING")
      return
    end
    @h.level += amount
    @h.starving = @h.level <= 0.25
    e.set(@h)
    # Fact encoded via comparison, not formatting: the payload's f32
    # 0.125 is exact in binary, so equality is deterministic.
    log(amount == FEED_AMOUNT ? "RUBY_FED" : "RUBY_FED_BAD_AMOUNT")
  end

  def teardown
    log("RUBY_CTRL_DONE")
  end
end
