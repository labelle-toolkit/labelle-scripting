-- behavior.lua — the POC behavior (labelle-engine poc/language-plugins,
-- scripts/behavior.lua), ported from raw contract calls to the prelude
-- sugar this plugin actually ships: Entity wrappers, labelle.on instead of
-- a hand-rolled poll loop, table payloads instead of hand-built JSON.
-- Same observable behavior: +10 x per tick, bullet + emit on the third
-- tick, react to host tick 4 by writing TickLog.

local player

-- Receive side: handler sugar over the contract's subscribe + poll-drain.
-- Registered at chunk load (before init), fired from the Controller's
-- inbox dispatch at the top of each tick.
labelle.on("tick_started", function(ev)
    if ev.n == 4 then
        player:set("TickLog", { last = 4 })
        labelle.log("lua: saw tick 4")
    end
end)

function init()
    player = Entity.new()
    player:set("Position", { x = 0, y = 0 })
    labelle.log("lua: player " .. player.id .. " ready")
end

function update(dt)
    local pos = player:get("Position")
    pos.x = pos.x + 10
    player:set("Position", pos)

    -- On the third tick: spawn a bullet and tell the world about it.
    if pos.x == 30 then
        local bullet = Entity.new()
        bullet:set("Bullet", { vx = 0, vy = -500 })
        labelle.emit("bullet_spawned", { owner = player.id })
        labelle.log("lua: bullet away")
    end
end
