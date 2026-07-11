# The POC behavior, ported to the real Script class: the same five-tick
# world the lua/ruby/ts/rust suites drive (create player at the origin,
# +10/tick, bullet + emit on tick 3, tick_started subscriber reacting to
# n == 4) — one contract, every language, identical world.

class Behavior < Labelle::Script
  @player : Labelle::EntityId = 0_u64
  # Reused across ticks — steady state reads Position with zero
  # allocation (the module's Buffer idiom).
  @pos = Labelle::Buffer.new

  def init : Nil
    @player = Labelle.create_entity
    raise "entity_create failed" if @player == 0
    raise "set failed" unless Labelle.set_component(@player, "Position", %({"x":0,"y":0}))
    Labelle.subscribe("tick_started")
    Labelle.log("crystal: player #{@player} ready")
  end

  def on_event(name : String, payload : String) : Nil
    if name == "tick_started" && payload.includes?(%("n":4))
      Labelle.set_component(@player, "TickLog", %({"last":4}))
      Labelle.log("crystal: saw tick 4")
    end
  end

  def update(dt : Float32) : Nil
    return unless Labelle.get_component_into(@player, "Position", @pos)
    x = (Util.i64_field(@pos.to_slice, %("x":)) || 0_i64) + 10
    Labelle.set_component(@player, "Position", %({"x":#{x},"y":0}))

    if x == 30
      bullet = Labelle.create_entity
      Labelle.set_component(bullet, "Bullet", %({"vx":0,"vy":-500}))
      Labelle.emit("bullet_spawned", %({"owner":#{@player}}))
      Labelle.log("crystal: bullet away")
    end
  end
end
