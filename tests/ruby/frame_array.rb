# frame_array.rb — Labelle::FrameArray semantics: `clear` keeps the
# backing (len = 0, no reallocation — mruby's Array#clear would FREE it),
# `<<` appends in bounds, growth only on overflow and counted. The
# steady-state no-growth-across-ticks property is asserted in
# zero_alloc.rb; this pins the unit behavior.

def init
  fa = Labelle::FrameArray.new(4)
  raise "fresh size" unless fa.size == 0 && fa.empty? && fa.capacity == 4

  fa << 1 << 2 << 3
  raise "append size" unless fa.size == 3 && !fa.empty?
  raise "aref" unless fa[0] == 1 && fa[2] == 3
  raise "aref out of logical bounds" unless fa[3].nil? && fa[-1].nil?

  sum = 0
  fa.each { |v| sum += v }
  raise "each" unless sum == 6

  fa[1] = 20
  raise "aset" unless fa[1] == 20

  fa.clear
  raise "clear keeps capacity" unless fa.size == 0 && fa.capacity == 4 && fa.growth_count == 0
  fa << 9
  raise "reuse after clear" unless fa[0] == 9 && fa.size == 1

  # Deliberate growth: the 5th append overflows cap 4 — ONE doubling,
  # counted, contents intact.
  fa.clear
  i = 0
  while i < 5
    fa << i
    i += 1
  end
  raise "growth" unless fa.size == 5 && fa.growth_count == 1 && fa.capacity == 8
  raise "content after growth" unless fa[4] == 4 && fa[0] == 0
  raise "to_a" unless fa.to_a == [0, 1, 2, 3, 4]

  Labelle::Entity.create.set("FrameArrayOk", ok: true)
end
