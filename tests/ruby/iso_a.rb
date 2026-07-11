# iso_a.rb — half of the top-level hook isolation pair (with iso_b.rb):
# both scripts define the SAME hook names with their own @ivar state.
# mruby has no lua-style per-chunk _ENV — without the harvest protocol,
# the second definition would clobber the first on Object and one script
# would tick twice while the other went silent.

def init
  @e = Labelle::Entity.create
  @e.set("IsoA", n: 0)
end

def update(dt)
  c = @e.get("IsoA")
  c[:n] += 1
  @e.set("IsoA", c)
end

def deinit
  Labelle.log("iso_a deinit")
end
