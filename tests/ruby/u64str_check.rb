# u64str_check.rb — pins Labelle.u64str, the unsigned-decimal renderer
# for entity ids. Ids live in ruby as the SIGNED bitcast of the host's
# u64, so bit-63 ids look negative to interpolation; u64str must render
# the true unsigned value across the whole range. The bit-63 literals are
# written as their signed bitcasts because that IS the ruby-side value —
# and because mruby (no bigint gem) cannot even parse the unsigned
# spellings. Results land in a component so the Zig side asserts the
# exact decimal strings (sorted-key encoding).

def init
  e = Labelle::Entity.create
  e.set("U64Str",
        zero: Labelle.u64str(0),
        one: Labelle.u64str(1),
        pow62: Labelle.u64str(1 << 62),
        # -9223372036854775807 == the signed bitcast of 0x8000000000000001
        high_one: Labelle.u64str(-9223372036854775807),
        # -1 == the signed bitcast of 0xFFFFFFFFFFFFFFFF
        all_ones: Labelle.u64str(-1))
end
