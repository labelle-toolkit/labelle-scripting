# behavior.rb — the POC behavior, ruby edition (the lua suite's
# behavior.lua ported to the prelude this sub-module ships): Entity
# wrappers, Labelle.on instead of a hand-rolled poll loop, Hash payloads.
# Same observable behavior: +10 x per tick, bullet + emit on the third
# tick, react to host tick 4 by writing TickLog.
#
# Ruby-specific shape: state lives in @ivars on the script's private
# receiver, and the subscription happens in `init` so the block captures
# that receiver (a chunk-scope block would capture `main` instead — its
# @ivars are not the hooks').

def init
  @player = Labelle::Entity.create
  @player.set("Position", x: 0, y: 0)
  Labelle.on("tick_started") do |ev|
    if ev[:n] == 4
      @player.set("TickLog", last: 4)
      Labelle.log("ruby: saw tick 4")
    end
  end
  Labelle.log("ruby: player #{@player.id} ready")
end

def update(dt)
  pos = @player.get("Position")
  pos[:x] += 10
  @player.set("Position", pos)

  # On the third tick: spawn a bullet and tell the world about it.
  if pos[:x] == 30
    bullet = Labelle::Entity.create
    bullet.set("Bullet", vx: 0, vy: -500)
    Labelle.emit("bullet_spawned", owner: @player.id)
    Labelle.log("ruby: bullet away")
  end
end
