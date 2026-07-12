# scripts/10_spawner.rb — the plain top-level-hooks tier
# (init/update/deinit): seeds the world and commands a feeding over the
# engine bus. State lives in @ivars on the script's private receiver;
# the `engine__tick` subscription happens in `init` so the block
# captures that receiver (a file-scope block would capture `main`
# instead — its @ivars are not the hooks').
#
# The `10_` prefix is the scripts/-dir ordering convention (the same
# structure Zig scripts use — labelle-engine#237): registration order
# is explicit — spawner, then 20_hunger_controller, then the unnumbered
# feed_watcher — and the prefix strips from the registered stem, so
# tracebacks and the generated main say "spawner".
#
# Each observable milestone logs ONE `RUBY_<TOKEN>` line so CI can
# `grep -oE '(RUBY|ZIG)_[A-Z0-9_.]+'` and diff the exact ordered
# sequence. This script's slice of the 5-frame timeline
# (LABELLE_NULL_FRAMES=5; scripts/20_hunger_controller.rb documents the
# full interleaving):
#
#   setup   RUBY_INIT              init(): Worker entity created, Hunger
#                                   attached BARE — the declared
#                                   defaults (components/hunger.rb,
#                                   level 0.875) seed the decay chain
#   tick 2  RUBY_FEED_SENT         emit hunger__feed{entity, amount: 0.5}
#                                   (script updates run BEFORE controller
#                                   ticks, so this precedes tick 2's
#                                   RUBY_LEVEL_* token; the emit reaches
#                                   THREE subscribers off one bus — the
#                                   native hooks/feed_watcher.zig at this
#                                   frame's dispatchEvents, the ruby
#                                   controller handler AND the pure-ruby
#                                   scripts/feed_watcher.rb on tick 3's
#                                   inbox)
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

  # The worker the HungerController manages. The Hunger set is BARE —
  # the contract's all-defaults `{}` write — so the component arrives
  # with its DECLARED defaults: level 0.875 (7/8, exact in binary
  # floating point at every width en route), declared in ruby in
  # components/hunger.rb. The decay chain starting at 0.875 therefore
  # proves the DECLARATION traveled schema -> codegen -> registry ->
  # ECS — an explicit write here would mask exactly that.
  @worker = Labelle::Entity.create
  @worker.set("Hunger")
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
