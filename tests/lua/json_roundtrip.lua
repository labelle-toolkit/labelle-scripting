-- json_roundtrip.lua — proves the prelude's pure-Lua JSON codec on the
-- shapes component payloads actually take: nested objects, arrays, integer
-- vs float numbers, escapes, \u escapes, booleans, null, empty tables.
-- Verdict lands in a RoundTrip component for the Zig side to assert.

function init()
    local original = {
        name = "ship \"X\"\n\\end",
        hp = 42,
        ratio = 1.5,
        neg = -2.25,
        pos = { x = 1.5, y = -2 },
        tags = { "a", "b", "c" },
        flags = { active = true, dead = false },
        empty = {},
    }
    local d = json.decode(json.encode(original))
    local ok = d.name == original.name
        and d.hp == 42 and math.type(d.hp) == "integer"
        and d.ratio == 1.5 and d.neg == -2.25
        and d.pos.x == 1.5 and d.pos.y == -2
        and #d.tags == 3 and d.tags[3] == "c"
        and d.flags.active == true and d.flags.dead == false
        and type(d.empty) == "table" and next(d.empty) == nil

    -- Decode-only shapes a host may hand us: whitespace everywhere,
    -- unicode escapes, null fields, nested empty arrays.
    local extern = json.decode(
        ' { "u" : "\\u0041BC" , "gone" : null , "arr" : [ 1 , 2.5 , { "deep" : [ [ ] ] } ] } '
    )
    ok = ok
        and extern.u == "ABC"
        and extern.gone == nil
        and extern.arr[1] == 1
        and extern.arr[2] == 2.5
        and type(extern.arr[3].deep[1]) == "table"

    -- Deterministic (sorted-key) encoding is part of the codec's promise.
    ok = ok and json.encode({ b = 1, a = 2, c = 3 }) == '{"a":2,"b":1,"c":3}'

    local e = Entity.new()
    e:set("RoundTrip", { ok = ok })
end
