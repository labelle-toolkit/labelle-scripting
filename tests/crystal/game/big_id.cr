# The u64 fidelity pin: a bit-63 entity id (0x8000000000000001 — its
# decimal exceeds Int64) must survive create → query → format EXACTLY.
# Crystal carries ids as UInt64 natively, so the risk isn't a VM number
# type — it's a careless Float or Int64 hop in the wrapper/parse path
# (crystal's `to_i64` on an id-sized decimal would raise Overflow; a
# float hop would round silently). Every id below moves through pure
# UInt64 arithmetic; the raises (→ eviction) fire on any drift, and the
# components never land.

class BigId < Labelle::Script
  BIG = 0x8000000000000001_u64

  @ids = [] of Labelle::EntityId
  @scratch = Labelle::Buffer.new

  def init : Nil
    # The Zig test pre-seeds the mock's next id to BIG.
    id = Labelle.create_entity
    raise "created id drifted" unless id == BIG
    raise "set failed" unless Labelle.set_component(id, "Marker", %({"tag":42}))

    # Round-trip through the query path: the id crosses host JSON and
    # the wrapper's parse — bit-exactness is the whole point.
    raise "query failed" unless Labelle.query_into(%(["Marker"]), @ids, @scratch)
    raise "query missed the entity" unless @ids.size == 1
    raise "queried id drifted" unless @ids[0] == BIG

    # Write through the QUERIED id and render it unsigned — the Zig
    # side pins both the addressed entity and the exact decimal
    # (UInt64#to_s: 9223372036854775809, never a negative Int64 or a
    # rounded float).
    queried = @ids[0]
    raise "set through queried id failed" unless Labelle.set_component(queried, "BigId", %({"idstr":"#{queried}"}))
  end
end
