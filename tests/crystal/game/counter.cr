# The bystander: advances every tick and records the dt it read through
# `Labelle.dt` — proving the Controller's stamp reached the contract
# before updates ran, and that siblings keep running whatever the
# scripts around it do.

class Counter < Labelle::Script
  @e : Labelle::EntityId = 0_u64
  @n = 0_u32

  def init : Nil
    @e = Labelle.create_entity
  end

  def update(dt : Float32) : Nil
    # The stamped dt and the passed dt are the same tick value.
    raise "dt stamp skew" unless Labelle.dt == dt
    @n += 1
    # Keys sorted (dt < n) — the suites pin component JSON
    # byte-for-byte, matching the embedded preludes' sorted encoders.
    Labelle.set_component(@e, "Counter", %({"dt":#{dt},"n":#{@n}}))
  end
end
