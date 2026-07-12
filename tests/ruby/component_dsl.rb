# component_dsl.rb — the RUNTIME half of "one DSL, two consumers" (ruby
# spelling of tests/lua/component_ref.lua): the same chunk-scope
# Labelle.component lines the declare runner (tools/declare-ruby) reads as
# schema evaluate, here, to Component.ref-equivalent view classes — get
# into them, set from them, interchangeable with the explicit-fields ref.
#
# Numbers are picked to stay exact in binary floating point so the Zig
# side can assert component JSON byte-for-byte.

Hunger = Labelle.component "Hunger", level: 0.875, starving: false
RefHunger = Labelle::Component.ref("Hunger", :level, :starving)
Tag = Labelle.component "Tag", { kind: "none" }, persist: "transient"
Dead = Labelle.component "Dead", {}

def init
  # The view class carries its component identity, ref-parity shape.
  raise "wrong name" unless Hunger.component_name == "Hunger"
  raise "wrong fields" unless Hunger.component_fields == [:level, :starving]
  raise "ref/DSL fields disagree" unless RefHunger.component_fields == Hunger.component_fields
  raise "opts leaked into fields" unless Tag.component_fields == [:kind]

  e = Labelle::Entity.create

  # Write through the DSL view (instance knows its component name).
  h = Hunger.new
  h.level = 0.875
  h.starving = false
  raise "set from DSL view refused" unless e.set(h)

  # Read back INTO the DSL view — and into the v0.2 ref: same component.
  h2 = Hunger.new
  raise "get into DSL view failed" if e.get(Hunger, into: h2).nil?
  raise "level mismatch" unless h2.level == 0.875
  r = RefHunger.new
  raise "get_into ref failed" if e.get_into(RefHunger, r).nil?
  raise "ref and DSL view disagree" unless r.level == h2.level && r.starving == h2.starving

  # Mutate through the DSL view, write back, read via the string spelling.
  h2.level = 0.25
  h2.starving = true
  raise "write-back refused" unless e.set(h2)
  plain = e.get("Hunger")
  raise "string read disagrees" unless plain[:level] == 0.25 && plain[:starving] == true

  # The braced-spec + trailing-opts spelling still yields a working view.
  t = Tag.new
  t.kind = "worker"
  raise "tag set refused" unless e.set(t)

  # Zero-field marker views: set / has? / remove round-trip.
  raise "marker set refused" unless e.set(Dead.new)
  raise "marker missing" unless e.has?("Dead")
  raise "marker remove refused" unless e.remove("Dead")
  raise "marker survived remove" if e.has?("Dead")

  e.set("DslOk", ok: true)
end
