-- array_marker.lua — labelle.array: explicit empty arrays survive encode
-- ("[]" not "{}"), decode tags arrays so get→set round-trips preserve
-- arrayness, and the tag forces array form for mixed tables. Pure-JSON
-- properties assert inline (a failure evicts this script, which the Zig
-- side notices as missing components); the component round-trip is
-- asserted byte-for-byte from Zig.

function init()
    -- Encoder-level properties.
    assert(json.encode(labelle.array({})) == "[]", "tagged empty must be []")
    assert(json.encode({}) == "{}", "untagged empty stays an object")
    assert(json.encode(labelle.array({ 1, 2 })) == "[1,2]", "tagged sequence")
    assert(json.encode({ ways = labelle.array({}) }) == '{"ways":[]}',
        "nested tagged empty")
    -- Mixed edge: the tag forces array interpretation (strays dropped).
    local mixed = labelle.array({ 7, 8 })
    mixed.stray = true
    assert(json.encode(mixed) == "[7,8]", "tag overrides mixed keys")
    -- Decode attaches the marker: a decoded empty array re-encodes as [].
    local rt = json.decode('{"a":[],"b":[1]}')
    assert(json.encode(rt) == '{"a":[],"b":[1]}', "decode→encode keeps []")

    -- Component round-trip through the host: set with an explicit empty
    -- array, get it back, set it again UNTOUCHED — arrayness must hold
    -- across both hops without re-tagging.
    local e = Entity.new()
    e:set("Path", { waypoints = labelle.array({}) })
    e:set("PathAgain", e:get("Path"))
end
