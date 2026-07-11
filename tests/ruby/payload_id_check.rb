# payload_id_check.rb — u64 fidelity in EVENT PAYLOAD decode: the host
# emits {"owner":9223372036854775809} (bit 63 set, beyond mruby's i64
# literal range) and the Zig decoder's wrapping integer path must land it
# bit-exact on the signed bitcast raw_entity_create handed out — mruby
# itself would raise RangeError before a ruby-side parse could finish.
# The handler wrapping the payload id and writing to the RIGHT entity is
# what the Zig side asserts against the u64 id.

def init
  @me = Labelle::Entity.create # the mock hands out 0x8000000000000001
  @me.set("Marker", tag: 42)
  Labelle.on("owner__ping") do |ev|
    raise "payload id must decode as an Integer" unless ev[:owner].is_a?(Integer)
    raise "payload id must equal the created id bit-for-bit" unless ev[:owner] == @me.id
    e = Labelle::Entity.wrap(ev[:owner])
    raise "wrapped payload id must address the created entity" unless e.has?("Marker")
    m = e.get("Marker")
    e.set("Owned", seen: true, tag: m[:tag])
  end
end
