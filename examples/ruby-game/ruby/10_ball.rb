# 10_ball.rb — the plain top-level-hooks tier (lua-smoke parity): one .rb
# file driving the REAL engine through the Script Runtime Contract from
# the assembler's generated main. State lives in @ivars on the script's
# private receiver; the engine__tick subscription happens in `init` so
# the block captures that receiver (a file-scope block would capture
# `main` instead — its @ivars are not the hooks').
#
# Each observable milestone logs ONE `RUBY_<TOKEN>` line (facts are
# encoded IN the token so CI can grep and diff the exact ordered
# sequence — see `.github/workflows/ci.yml` → `ruby-example`).
#
#   setup   RUBY_INIT              init(): entity created + Position set
#   tick 1  RUBY_TICK_1            (subscriptions from setup turn ACTIVE
#                                   at this tick's drain boundary)
#   tick 2  RUBY_TICK_2
#   tick 3  RUBY_ENGINE_TICK_SEEN  first engine__tick arrives (emitted by
#                                   Game.tick, drained tick 2, inbox-
#                                   dispatched at tick start)
#           RUBY_TICK_3
#           RUBY_MOVED_X_30        Position read-modify-write hit x=30
#   tick 4  RUBY_TICK_4
#   tick 5  RUBY_TICK_5
#   deinit  RUBY_BALL_DEINIT       shutdown reaches per-script deinit
#
# Why the one-frame latencies: subscriptions activate at drain boundaries
# (no same-tick replay) and handlers run on the NEXT tick's inbox
# dispatch — see labelle-engine/src/script_contract.zig "Event tap
# semantics".

def init
  @tick = 0
  @engine_tick_seen = false
  @ball = Labelle::Entity.create
  @ball.set("Position", x: 0, y: 0)

  # An ENGINE event that fires every frame in any game shape — proving
  # the engine's own bus reaches ruby handlers through the tap.
  Labelle.on("engine__tick") do |ev|
    unless @engine_tick_seen
      @engine_tick_seen = true
      Labelle.log("RUBY_ENGINE_TICK_SEEN frame=#{ev[:frame_number]}")
    end
  end

  Labelle.log("RUBY_INIT id=#{Labelle.u64str(@ball.id)}")
end

def update(dt)
  @tick += 1
  Labelle.log("RUBY_TICK_#{@tick}")

  # Move the entity: +10 x per tick through the contract's component
  # get/set (Position routes through setPosition, so render dirty-
  # tracking fires exactly as for Zig scripts).
  pos = @ball.get("Position")
  pos[:x] += 10
  @ball.set("Position", pos)
  Labelle.log("RUBY_MOVED_X_30") if pos[:x] == 30
end

def deinit
  Labelle.log("RUBY_BALL_DEINIT")
end
