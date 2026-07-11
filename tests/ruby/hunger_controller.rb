# hunger_controller.rb — the RFC's HungerController reference, verbatim
# ergonomics (the acceptance surface #742 pins):
#
#   - Labelle::Component.ref builds the Struct-backed view class,
#   - the controller caches ONE instance in setup,
#   - tick refills it per entity via get(Hunger, into: @h), mutates
#     fields, writes back with e.set(@h),
#   - command-as-event feeding (hunger__feed) subscribed in setup,
#   - plain hooks coexist: a top-level init seeds the worker.
#
# Numbers are picked to stay exact in binary floating point (0.875,
# 0.25 steps) so the Zig side can assert component JSON byte-for-byte.

Hunger = Labelle::Component.ref("Hunger", :level, :starving)

def init
  w = Labelle::Entity.create
  w.set("Hunger", level: 0.875, starving: false)
  w.set("Worker")
  Labelle.log("ruby: worker #{w.id} ready")
end

class HungerController < Labelle::Controller
  DECAY = 0.5

  def setup
    @h = Hunger.new # once, in setup — the cached zero-alloc view
    on("hunger__feed") { |ev| feed(ev[:entity], ev[:amount] || 0.5) }
    log("ruby: hunger controller ready")
  end

  def tick(dt)
    each("Hunger", "Worker") do |e|
      e.get(Hunger, into: @h) # REFILLS the cached instance
      @h.level -= DECAY * dt
      @h.starving = @h.level <= 0.25
      e.set(@h) # instance knows its component; writes to THIS entity
    end
  end

  # Same-VM public API for other ruby code (the command handler above).
  def feed(id, amount)
    e = entity(id)
    e.get(Hunger, into: @h)
    @h.level += amount
    @h.starving = @h.level <= 0.25
    e.set(@h)
  end

  def teardown
    log("ruby: hunger controller done")
  end
end
