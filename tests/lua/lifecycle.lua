-- lifecycle.lua — covers the hooks and contract corners no other test
-- touches: deinit() (observable through a log + emit, since the VM is gone
-- afterwards), prefab spawning, scene changes, and component remove/has.

local marker

function init()
    marker = Entity.new()
    marker:set("Alive", {})

    -- Prefab + scene, including the failure arms.
    local ship = labelle.spawn("ship", { x = 5, y = 10 })
    assert(ship ~= nil)
    ship:set("Tag", { kind = "spawned" })
    assert(labelle.scene_change("menu"))
    assert(not labelle.scene_change("nope"))

    -- Remove is idempotent; has flips accordingly.
    assert(marker:has("Alive"))
    assert(marker:remove("Alive"))
    assert(not marker:has("Alive"))
    assert(marker:remove("Alive")) -- absent-but-known removes still ok
end

function deinit()
    labelle.log("lua: lifecycle deinit ran")
    labelle.emit("shutdown_done", { from = marker.id })
end
