-- event_declared.lua — the runtime half of labelle.event (one DSL, two
-- consumers): the SAME line the declare runner reads as an event-schema
-- declaration evaluates HERE to the event-name string itself, so one
-- binding drives both legs of the bus — labelle.emit(HungerFeed, ...)
-- toward the host and labelle.on(HungerFeed, ...) back from it.
-- labelle.id is plain 0 at runtime. Chunk-scope findings (returned name,
-- id value, the name-validation errors) assert via error(), which evicts
-- the script — so the Fed component existing at all is half the proof.

local HungerFeed = labelle.event("hunger__feed", { entity = labelle.id, amount = 0.5 })

if HungerFeed ~= "hunger__feed" then
    error("event did not return its name")
end
if labelle.id ~= 0 then
    error("labelle.id is not 0 at runtime")
end

local ok, err = pcall(labelle.event, "")
if ok or not tostring(err):find("non%-empty event name") then
    error("empty event name accepted or wrong error: " .. tostring(err))
end
ok, err = pcall(labelle.event, 42)
if ok or not tostring(err):find("non%-empty event name") then
    error("non-string event name accepted or wrong error: " .. tostring(err))
end

local state
local sent = false

labelle.on(HungerFeed, function(ev)
    local s = state:get("Fed")
    s.count = s.count + 1
    s.amount = ev.amount
    state:set("Fed", s)
end)

function init()
    state = Entity.new()
    state:set("Fed", { count = 0, ok = true })
end

function update(dt)
    -- Emit through the binding once, toward the host (the mock captures
    -- script→host emissions verbatim).
    if sent then return end
    sent = true
    labelle.emit(HungerFeed, { entity = labelle.u64str(state.id), amount = 0.5 })
end
