# counter.rb — the "innocent bystander" script for the error-isolation
# tests: registered AFTER scripts that break, it proves the Controller
# keeps ticking the rest. Also records Labelle.time_dt so the tests can
# assert the dt stamp reached script-land.

def init
  @e = Labelle::Entity.create
  @e.set("Counter", n: 0, dt: 0)
end

def update(dt)
  c = @e.get("Counter")
  c[:n] += 1
  c[:dt] = Labelle.time_dt
  @e.set("Counter", c)
end
