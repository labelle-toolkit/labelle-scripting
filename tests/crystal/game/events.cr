# The receive side: subscribe + drain, decoded payloads, and the
# plugin-wide inbox fanning out to EVERY live script (the suite
# registers two instances of this class under different component names
# — both must see both deliveries of one tick).

class EventCounter < Labelle::Script
  @e : Labelle::EntityId = 0_u64
  @count = 0_u32
  @amount = 0_i64
  @nested_ok = false

  def initialize(@component : String)
  end

  def init : Nil
    @e = Labelle.create_entity
    Labelle.subscribe("cargo__delivered")
    write
  end

  def on_event(name : String, payload : String) : Nil
    return unless name == "cargo__delivered"
    @count += 1
    @amount = Util.i64_field(payload.to_slice, %("amount":)) || -1_i64
    # Nested payloads arrive intact (a structural spot-check — full
    # decoding is the script's own business in slice 1).
    @nested_ok = payload.includes?(%("tags":["fragile"]))
    write
  end

  private def write : Nil
    Labelle.set_component(@e, @component, %({"amount":#{@amount},"count":#{@count},"nested_ok":#{@nested_ok}}))
  end
end
