# iso_b.rb — see iso_a.rb: same hook names, own state, both must run.

def init
  @e = Labelle::Entity.create
  @e.set("IsoB", n: 0)
end

def update(dt)
  c = @e.get("IsoB")
  c[:n] += 10
  @e.set("IsoB", c)
end

def deinit
  Labelle.log("iso_b deinit")
end
