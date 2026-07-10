-- event_payload.lua — the dispatch test: labelle.on handlers must fire
-- once per drained event, in FIFO order, with the payload decoded to a
-- table (nested structures included). Two handlers on one name prove
-- fan-out. Findings go into the Seen component.

local state

labelle.on("cargo__delivered", function(ev)
    local s = state:get("Seen")
    s.count = s.count + 1
    s.amount = ev.amount
    s.nested_ok = (ev.box.w == 2 and ev.box.tags[1] == "fragile")
    state:set("Seen", s)
end)

-- Second handler on the same event: fan-out in registration order.
labelle.on("cargo__delivered", function(ev)
    local s = state:get("Seen")
    s.fanout = (s.fanout or 0) + 1
    state:set("Seen", s)
end)

function init()
    state = Entity.new()
    state:set("Seen", { count = 0, fanout = 0 })
end
