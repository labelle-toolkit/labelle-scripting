-- big_id_check.lua — round-trips a bit-63 entity id through the FULL query
-- path. The Zig test forces the mock's next id to 0x8000000000000001, so
-- raw_entity_create hands in the signed bitcast, the host's query response
-- spells the id as its unsigned decimal (> math.maxinteger — a tonumber()
-- there would degrade to an imprecise float), and the prelude's id-array
-- parser must wrap it back onto the exact same integer: get/set/has through
-- the QUERIED wrapper then hit the right entity, which the Zig side proves
-- by asserting components against the u64 id.

function init()
    local e = Entity.new() -- the mock hands out 0x8000000000000001
    e:set("Marker", { tag = 1 })

    local found, n = nil, 0
    for q in game.query("Marker") do
        n = n + 1
        found = q
    end
    assert(n == 1, "query must match exactly the one marked entity")
    assert(found.id == e.id, "parsed id must equal the created id bit-for-bit")
    assert(found:has("Marker"), "has() through the queried wrapper")

    local m = found:get("Marker") -- get through the queried wrapper
    m.tag = m.tag + 41
    found:set("Marker", m) -- set lands on the same entity, or Zig's assert fails

    found:set("BigId", { idstr = labelle.u64str(found.id) })
end
