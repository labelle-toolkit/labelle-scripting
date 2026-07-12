# scripts/20_hunger_controller.rb — the structured tier: the
# labelle-engine#742 acceptance pattern, verbatim ergonomics, against
# the REAL engine —
#
#   - `Hunger` is the view class components/hunger.rb DECLARES (the
#     labelle-engine#237 refinement, assembler v0.86.0): components-dir
#     declarations register BEFORE scripts/, so the constant exists by
#     the time this chunk loads — no `Component.ref` line here anymore
#     (`Component.ref` stays the explicit-fields spelling of the same
#     class; the two are interchangeable),
#   - the controller caches ONE instance in setup (`@h = Hunger.new`),
#   - tick refills it per entity via `e.get(Hunger, into: @h)`, mutates
#     fields, writes back with `e.set(@h)`,
#   - command-as-event feeding (`hunger__feed` — DECLARED IN RUBY,
#     events/hunger__feed.rb) subscribed in setup — emitted by
#     scripts/10_spawner.rb on tick 2, so the cross-script round-trip
#     over the engine bus is part of the pinned transcript,
#   - `Labelle::FrameArray` is the per-frame HOT scratch (collect ids,
#     then process — mruby's Array#clear would FREE the backing every
#     tick), asserted flat via growth_count at tick 5,
#   - plain hooks coexist: scripts/10_spawner.rb seeds the worker,
#   - the SAME hunger__feed reaches two more subscribers off the same
#     bus: a NATIVE game-root Zig hook (hooks/feed_watcher.zig — the
#     two-layer interop) and a pure-ruby top-level watcher
#     (scripts/feed_watcher.rb).
#
# Tokens carry BEHAVIOR: every tick logs the freshly written level, so
# the pinned sequence encodes the whole decay-feed-decay sawtooth through
# the real ECS. All values are exact in binary floating point at every
# width en route (0.875 start, 0.25 steps, 0.5 feed), so the interpolated
# decimals are deterministic. The 0.875 seed is the DECLARED default from
# components/hunger.rb (the spawner attaches Hunger bare), so the chain
# also proves the ruby declaration traveled through codegen into the real
# ECS. One deliberate delta from the #742 fixture: decay is 0.25 PER
# TICK, not `DECAY * dt` — the null backend's fixed dt is f32(1.0/60.0),
# which no decimal-exact multiple survives, and exact values in the
# tokens are the point.
#
# Frame-by-frame (LABELLE_NULL_FRAMES=5; per frame the plugin Controller
# runs: event inbox → script `update`s → controller `tick`s):
#
#   setup   RUBY_INIT             (spawner init: worker seeded with the
#                                  declared default, 0.875)
#           RUBY_CTRL_READY       controller setup ran (after ALL inits)
#   tick 1  RUBY_LEVEL_0.625      0.875 - 0.25 decay, written back
#   tick 2  RUBY_FEED_SENT        (spawner update: emits hunger__feed)
#           RUBY_LEVEL_0.375      0.625 - 0.25 — tick 1's write PERSISTED
#           ZIG_FEED_SEEN_0.5     (hooks/feed_watcher.zig — the native
#                                  subscriber, at THIS frame's
#                                  dispatchEvents: frame end, after the
#                                  controller ticks, one tick BEFORE the
#                                  ruby handlers' inbox dispatch)
#   tick 3  RUBY_ENGINE_TICK_SEEN (spawner's builtin sub, same inbox)
#           RUBY_WATCHER_SAW_0.5  (scripts/feed_watcher.rb — the THIRD
#                                  subscriber, same inbox dispatch;
#                                  per-event handlers run in SUBSCRIPTION
#                                  order and its file-scope sub happened
#                                  at chunk load, before this
#                                  controller's setup-time `on`)
#           RUBY_FED_LEVEL_0.875  inbox: feed handler ran — id + exact
#                                  f32 0.5 amount round-tripped the bus;
#                                  0.375 + 0.5 re-read AFTER the write
#           RUBY_LEVEL_0.625      0.875 - 0.25 — decay resumes on the fed
#   tick 4  RUBY_LEVEL_0.375
#   tick 5  RUBY_LEVEL_0.125
#           RUBY_STARVING         0.125 <= 0.25 crossed the threshold
#           RUBY_FRAMEARRAY_OK    warmed hot scratch never grew
#                                  (growth_count == 0 across all 5 ticks)
#   deinit  RUBY_CTRL_DONE        teardown (before per-script deinits)

class HungerController < Labelle::Controller
  DECAY_PER_TICK = 0.25 # exact in binary fp — see the header
  STARVE_AT = 0.25
  FEED_DEFAULT = 0.5

  def setup
    @h = Hunger.new # once, in setup — the cached zero-alloc view
    @fa = Labelle::FrameArray.new(8) # hot per-frame scratch; backing survives clear
    @tick = 0
    @was_starving = false
    # Guard the payload: a malformed hunger__feed without :entity would
    # raise in the binding (isolated + logged, but noisy) — exemplar code
    # shows the guard.
    on("hunger__feed") { |ev| feed(ev[:entity], ev[:amount] || FEED_DEFAULT) if ev[:entity] }
    log("RUBY_CTRL_READY")
  end

  def tick(dt)
    @tick += 1

    # The FrameArray idiom in the hot path: clear keeps the backing,
    # collect this tick's ids, then process — stash e.id, never e
    # (`each` reuses one wrapper object across iterations).
    @fa.clear
    each("Hunger", "Worker") { |e| @fa << e.id }

    i = 0
    while i < @fa.size
      e = entity(@fa[i])
      # get returns false when the component vanished between the query
      # and this read (entity destroyed / component removed mid-tick) —
      # guard it, or a stale @h from the PREVIOUS iteration would be
      # written to THIS entity. (Plain `if`, not `next unless`: this is
      # a while loop, and skipping past `i += 1` would spin forever.)
      if e.get(Hunger, into: @h) # REFILLS the cached instance
        @h.level -= DECAY_PER_TICK
        @h.starving = @h.level <= STARVE_AT
        e.set(@h) # instance knows its component; writes to THIS entity

        # The token carries the written value — each tick's number is
        # only reachable through the PREVIOUS tick's persisted write, so
        # the sequence pins ECS persistence transitively.
        log("RUBY_LEVEL_#{@h.level}")

        if @h.starving && !@was_starving
          @was_starving = true
          log("RUBY_STARVING")
        end
      end
      i += 1
    end

    # growth_count()==0 baked into the token: 5 warmed ticks over a
    # capacity-8 scratch must never reallocate.
    if @tick == 5
      if @fa.growth_count == 0 && @fa.size == 1
        log("RUBY_FRAMEARRAY_OK")
      else
        log("RUBY_FRAMEARRAY_GREW_#{@fa.growth_count}_SIZE_#{@fa.size}")
      end
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
    @h.starving = @h.level <= STARVE_AT
    e.set(@h)
    # Re-read AFTER the write: the token carries what actually PERSISTED
    # in the ECS, not the in-memory instance.
    e.get(Hunger, into: @h)
    log("RUBY_FED_LEVEL_#{@h.level}")
  end

  def teardown
    log("RUBY_CTRL_DONE")
  end
end
