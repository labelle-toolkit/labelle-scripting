# crystal/hunger.cr — the labelle-engine#742 HungerController pattern,
# ported to the native family (crystal twin of rust-game's hunger.rs):
#
#   - a plain class inheriting `Labelle::Script`, ALL state in instance
#     vars — no VM, no registry magic,
#   - the buffer-reuse idiom at every contract boundary: caller-owned
#     `Labelle::Buffer`s held in instance vars, refilled per tick by
#     `query_into` / `get_component_into` (grow-once wrappers; the ids
#     Array's `clear` retains its backing store) and parsed straight
#     from `Buffer#to_slice` — crystal Strings are immutable, so the
#     WRITE side interpolates a fresh String per write (the language's
#     contract; rust reuses a String buffer there instead). Pinned
#     settled by CRYSTAL_BUFFERS_OK at tick 5: the Buffer pair carries
#     the pin, since crystal's Array capacity is not introspectable
#     (tests/crystal/game/gc_churn.cr's discipline, rehearsed over a
#     real game frame),
#   - command-as-event feeding (`hunger__feed`, events/hunger__feed.zig)
#     subscribed in `init` — emitted by crystal/spawner.cr on tick 2, so
#     the cross-script round-trip over the engine bus is part of the
#     pinned transcript,
#   - a NATIVE game-root Zig hook (hooks/feed_watcher.zig) consumes the
#     SAME hunger__feed from the same bus — the two-layer interop.
#
# `Hunger` is a real engine component (components/hunger.zig) — crystal
# has no declare mode, so every call addresses it by name over the
# contract at runtime. Timeline: game.cr's header.

class HungerSystem < Labelle::Script
  DECAY_PER_TICK = 0.25_f32 # exact in binary fp — see game.cr
  STARVE_AT      = 0.25_f32
  FEED_DEFAULT   =  0.5_f32

  # Reused across ticks — after tick 1's warm-up the steady state's
  # contract reads allocate nothing (CRYSTAL_BUFFERS_OK pins it).
  @ids = [] of Labelle::EntityId
  @scratch = Labelle::Buffer.new
  @comp = Labelle::Buffer.new
  @tick = 0_u32
  @was_starving = false
  # Buffer capacities recorded after tick 1 (the warm-up); any later
  # movement flips @grew — the growth_count()==0 analog.
  @warm_caps : {Int32, Int32}?
  @grew = false

  def init : Nil
    # Size the payload buffer ONCE, with headroom: get-into growth is
    # required-size-exact, and this component's JSON changes length
    # mid-run ("starving":false → true) — headroom keeps the capacity
    # pin meaningful instead of tracking payload width.
    @comp.ensure_capacity(64)
    Labelle.subscribe("hunger__feed")
    Labelle.log("CRYSTAL_CTRL_READY")
  end

  def on_event(name : String, payload : String) : Nil
    return unless name == "hunger__feed"
    # Guard the payload: a malformed hunger__feed without an entity has
    # no target — exemplar code shows the guard (mirrors the rust
    # handler's let-else).
    entity = Game.u64_field(payload.to_slice, %("entity":))
    return unless entity
    amount = Game.f32_field(payload.to_slice, %("amount":)) || FEED_DEFAULT
    feed(entity, amount)
  end

  def update(dt : Float32) : Nil
    @tick += 1

    # The hot-path reuse idiom: the ids Array and both Buffers are
    # cleared (capacity retained) and refilled by the wrapper — no
    # per-tick list, no per-read buffer.
    return unless Labelle.query_into(%(["Hunger","Worker"]), @ids, @scratch)

    @ids.each do |id|
      # get returns false when the component vanished between the query
      # and this read (entity destroyed / component removed mid-tick) —
      # guard it rather than acting on the PREVIOUS iteration's stale
      # buffer.
      next unless Labelle.get_component_into(id, "Hunger", @comp)
      level = (self.level || 0.0_f32) - DECAY_PER_TICK
      starving = level <= STARVE_AT
      write_hunger(id, level, starving)

      # The token carries the written value — each tick's number is
      # only reachable through the PREVIOUS tick's persisted write, so
      # the sequence pins ECS persistence transitively.
      Labelle.log("CRYSTAL_LEVEL_#{level}")

      if starving && !@was_starving
        @was_starving = true
        Labelle.log("CRYSTAL_STARVING")
      end
    end

    # The growth pin: record the Buffer capacities after tick 1's
    # warm-up; ticks 2..5 must not move EITHER (grow-once wrappers +
    # capacity-retaining clears — the whole idiom).
    caps = {@scratch.capacity, @comp.capacity}
    if @tick == 1
      @warm_caps = caps
    elsif (warm = @warm_caps) && caps != warm
      @grew = true
    end
    if @tick == 5
      if !@grew && @ids.size == 1
        Labelle.log("CRYSTAL_BUFFERS_OK")
      else
        Labelle.log("CRYSTAL_BUFFERS_MOVED_SIZE_#{@ids.size}")
      end
    end
  end

  def deinit : Nil
    Labelle.log("CRYSTAL_CTRL_DONE")
  end

  # Read `level` from the freshly filled component buffer.
  private def level : Float32?
    Game.f32_field(@comp.to_slice, %("level":))
  end

  # Whole-struct REPLACE write through the contract (absent fields would
  # take declared defaults — this game always writes both).
  private def write_hunger(id : Labelle::EntityId, level : Float32, starving : Bool) : Nil
    Labelle.set_component(id, "Hunger", %({"level":#{level},"starving":#{starving}}))
  end

  # Same-class API for the command handler above — the ruby controller's
  # `feed` method, verbatim story.
  private def feed(id : Labelle::EntityId, amount : Float32) : Nil
    unless Labelle.get_component_into(id, "Hunger", @comp)
      Labelle.log("CRYSTAL_FEED_TARGET_MISSING")
      return
    end
    new_level = (self.level || 0.0_f32) + amount
    write_hunger(id, new_level, new_level <= STARVE_AT)
    # Re-read AFTER the write: the token carries what actually PERSISTED
    # in the ECS, not the in-memory value.
    if Labelle.get_component_into(id, "Hunger", @comp)
      Labelle.log("CRYSTAL_FED_LEVEL_#{self.level || 0.0_f32}")
    end
  end
end
