# arena_probe.rb — reads the ABSOLUTE GC arena index at a fixed point of
# its first update and records it. The eviction-residue test runs it twice
# (fresh VM each): once alone, once after a batch of init-failing scripts
# — the two readings must be identical, because every eviction entry is
# supposed to restore the arena it consumed. An unrestored eviction
# ratchets the index up VM-wide, which this probe sees as a higher base.

def update(dt)
  e = Labelle::Entity.create
  e.set("ProbeArena", a: Labelle.raw_gc_arena)
end
