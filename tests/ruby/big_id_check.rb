# big_id_check.rb — round-trips a bit-63 entity id through the FULL query
# path. The Zig test forces the mock's next id to 0x8000000000000001, so
# raw_entity_create hands in the signed bitcast, the host's query response
# spells the id as its unsigned decimal, and the raw_query shim's Zig-side
# wrapping parse must land it back on the exact same integer (mruby
# integer arithmetic raises on overflow, so a ruby-side parse could not
# even be written): get/set/has? through the QUERIED id then hit the
# right entity, which the Zig side proves by asserting components against
# the u64 id.

def init
  e = Labelle::Entity.create # the mock hands out 0x8000000000000001
  e.set("Marker", tag: 1)

  found_id = nil
  n = 0
  Labelle.each("Marker") do |q|
    n += 1
    found_id = q.id # stash the ID — the yielded wrapper is reused
  end
  raise "query must match exactly one entity" unless n == 1
  raise "parsed id must equal the created id bit-for-bit" unless found_id == e.id

  found = Labelle::Entity.wrap(found_id)
  raise "has? through the wrapped id" unless found.has?("Marker")

  m = found.get("Marker")
  m[:tag] += 41
  found.set("Marker", m) # lands on the same entity, or Zig's assert fails

  found.set("BigId", idstr: Labelle.u64str(found.id))
end
