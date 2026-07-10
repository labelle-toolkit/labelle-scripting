-- payload_id_check.lua — u64 fidelity in EVENT PAYLOAD decode: the host
-- emits {"owner":9223372036854775809} (bit 63 set, beyond math.maxinteger)
-- and json.decode's wrapping integer path must land it bit-exact on the
-- signed bitcast raw_entity_create handed out — tonumber() would round it
-- through a float and Entity.wrap(ev.owner) would address a wrong (or no)
-- entity. The handler's set() writing to the RIGHT entity is what the Zig
-- side asserts against the u64 id.

local me

labelle.on("owner__ping", function(ev)
    assert(math.type(ev.owner) == "integer", "payload id must decode as an integer")
    assert(ev.owner == me.id, "payload id must equal the created id bit-for-bit")
    local e = Entity.wrap(ev.owner)
    assert(e:has("Marker"), "wrapped payload id must address the created entity")
    local m = e:get("Marker")
    e:set("Owned", { seen = true, tag = m.tag })
end)

function init()
    me = Entity.new() -- the mock hands out 0x8000000000000001
    me:set("Marker", { tag = 42 })
end
