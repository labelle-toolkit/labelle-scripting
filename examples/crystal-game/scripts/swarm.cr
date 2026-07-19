# scripts/swarm.cr — the BULK-ACCESS example behavior (contract v1.3,
# labelle-scripting#44): a 3-boid swarm integrated through the typed
# batch block, `Labelle.batch(BoidView, BoidVelView) { |b, v| … }` — ONE
# batch_get + ONE batch_set per tick for the whole swarm (the
# whole-query fast path), where per-entity get/set would cross the FFI
# boundary 4× per boid. The `Labelle.batch_view` classes are
# WRITE-THROUGH views over the stream buffer, mirroring the DECLARED
# components (components/boid.cr / boid_vel.cr) field for field — the
# stride cross-check inside `Labelle.batch` verifies that against the
# real host stream every tick, so a drift refuses loudly instead of
# mis-mapping.
#
# The transcript pin: all values are exact in binary floating point
# (x₀ ∈ {1,2,3}, vx = 0.5), so after 5 ticks Σx = 6 + 3×2.5 = 13.5
# exactly and tick 5 logs `CRYSTAL_BATCH_OK_3_13.5` — count and checksum
# prove three entities round-tripped the stream five times through the
# REAL engine host (an engine < 2.6.0 would raise here: there is no
# batch fallback). The SUM is the pin on purpose: the engine's query
# order is not creation order, so any single entity's value would be
# order-dependent.

Labelle.batch_view BoidView, "Boid", {x: f32, y: f32}
Labelle.batch_view BoidVelView, "BoidVel", {vx: f32, vy: f32}

class Swarm < Labelle::Script
  @tick = 0

  def init : Nil
    3.times do |i|
      e = Labelle.create_entity
      Labelle.set_component(e, "Boid", %({"x":#{i + 1},"y":0}))
      Labelle.set_component(e, "BoidVel", %({"vx":0.5,"vy":0}))
    end
  end

  def update(dt : Float32) : Nil
    @tick += 1
    sum_x = 0.0_f32
    n = Labelle.batch(BoidView, BoidVelView) do |b, v|
      b.x += v.vx
      b.y += v.vy
      sum_x += b.x
    end
    Labelle.log("CRYSTAL_BATCH_OK_#{n}_#{sum_x}") if @tick == 5
  end
end
