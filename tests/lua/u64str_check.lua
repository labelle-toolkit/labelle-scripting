-- u64str_check.lua — pins labelle.u64str, the unsigned-decimal renderer
-- for entity ids. Ids live in Lua as the SIGNED bitcast of the host's u64,
-- so bit-63 ids look negative to %d; u64str must render the true unsigned
-- value across the whole range. Results land in a component so the Zig
-- side asserts the exact decimal strings (sorted-key encoding).

function init()
    local e = Entity.new()
    e:set("U64Str", {
        zero = labelle.u64str(0),
        one = labelle.u64str(1),
        pow62 = labelle.u64str(1 << 62),
        -- Lua 5.4 hex integer literals wrap: these ARE the signed bitcasts
        -- -9223372036854775807 and -1 of the two bit-63 u64 patterns.
        high_one = labelle.u64str(0x8000000000000001),
        all_ones = labelle.u64str(0xFFFFFFFFFFFFFFFF),
    })
end
