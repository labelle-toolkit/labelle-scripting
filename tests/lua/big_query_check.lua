-- big_query_check.lua — the grow-and-retry path: 420 entities with
-- 20-digit ids serialize to ~8.8 KB of id JSON, past the raw_query shim's
-- fixed 8 KiB buffer. The contract's snprintf-style return makes the
-- overflow detectable and the shim must retry right-sized, so game.query
-- yields ALL ids — a silent prefix would fail the count or the id-set
-- checks below (a failed assert evicts this script and leaves BigQuery
-- unset for the Zig side to catch).

local N = 420

function init()
    local created = {}
    for i = 1, N do
        local e = Entity.new()
        assert(e ~= nil, "mock refused entity " .. i .. " — raise MAX_ENTITIES?")
        e:set("Marker", { i = i })
        created[e.id] = true
    end

    local n = 0
    for q in game.query("Marker") do
        n = n + 1
        assert(created[q.id], "query yielded an id that was never created")
        created[q.id] = nil -- each id exactly once
    end
    assert(n == N, "query must yield ALL ids after the retry, got " .. n)
    assert(next(created) == nil, "every created id must appear in the result")

    local r = Entity.new()
    r:set("BigQuery", { count = n })
end
