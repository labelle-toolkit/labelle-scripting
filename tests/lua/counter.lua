-- counter.lua — the "innocent bystander" script for the error-isolation
-- test: registered AFTER a script whose update always throws, it proves
-- the Controller keeps ticking the rest. Also records labelle.time_dt()
-- so the test can assert the dt stamp reached script-land.

local e

function init()
    e = Entity.new()
    e:set("Counter", { n = 0, dt = 0 })
end

function update(dt)
    local c = e:get("Counter")
    c.n = c.n + 1
    c.dt = labelle.time_dt()
    e:set("Counter", c)
end
