# The query-growth pin: a result bigger than the buffers' starting
# capacity must arrive COMPLETE — `query_into`'s required-size retry
# (grow once, re-query) is under test, with 20-digit ids so the JSON is
# as fat as ids get. Every raise (→ eviction) means the verdict
# component never lands.

class BigQuery < Labelle::Script
  COUNT = 420

  @ids = [] of Labelle::EntityId
  # Deliberately tiny starting capacity: the first sizing leg MUST come
  # back required > capacity and the wrapper must grow exactly once.
  @scratch = Labelle::Buffer.new(64)

  def init : Nil
    # Ids pre-seeded near UInt64 max by the Zig test: 20-digit decimals,
    # ~21 bytes per id — the full result is ~8.8 KB of JSON.
    created = Array(Labelle::EntityId).new(COUNT)
    COUNT.times do
      id = Labelle.create_entity
      raise "create failed" if id == 0
      raise "set failed" unless Labelle.set_component(id, "Marker", %({"tag":1}))
      created << id
    end

    raise "query failed" unless Labelle.query_into(%(["Marker"]), @ids, @scratch)
    raise "growth premise broken — result fit 64 bytes?" unless @scratch.capacity > 64

    # ALL ids, each exactly once (order is not part of the contract).
    raise "truncated or duplicated result" unless @ids.size == COUNT
    got = @ids.dup
    got.sort!
    created.sort!
    raise "id set mismatch" unless got == created

    # The verdict entity — the (COUNT+1)th create, asserted Zig-side.
    verdict = Labelle.create_entity
    raise "verdict set failed" unless Labelle.set_component(verdict, "BigQuery", %({"count":#{@ids.size}}))
  end
end
