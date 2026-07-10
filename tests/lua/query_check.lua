-- query_check.lua — exercises game.query end to end: prelude iterator →
-- raw_query shim → contract → mock host id-JSON → Entity wrappers. Writes
-- its findings into a QueryResult component so the Zig test can assert on
-- them without reaching into the VM.

function init()
    for i = 1, 3 do
        local e = Entity.new()
        e:set("Marker", { i = i })
        if i == 2 then
            e:set("Extra", {})
        end
    end
    Entity.new() -- bare entity: must be invisible to every query below

    local count, sum = 0, 0
    for e in game.query("Marker") do
        count = count + 1
        sum = sum + e.id
        assert(e:has("Marker"))
    end

    local both = 0
    for e in game.query("Marker", "Extra") do
        both = both + 1
        assert(e:get("Marker").i == 2) -- the multi-name filter found the right one
    end

    local none = 0
    for _ in game.query("Nope") do
        none = none + 1
    end

    local r = Entity.new()
    r:set("QueryResult", { count = count, sum = sum, both = both, none = none })
end
