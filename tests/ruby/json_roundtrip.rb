# json_roundtrip.rb — proves the Zig-side JSON codec on the shapes
# component payloads actually take: nested objects, arrays, integer vs
# float numbers, escapes, \u escapes, booleans, null, empties. The lua
# suite needs labelle.array to disambiguate empty [] from {}; ruby gets
# the distinction natively (Hash vs Array), so this suite pins THAT — the
# codec must preserve it both ways, through the host included. Verdict
# lands in a RoundTrip component for the Zig side to assert.

def init
  original = {
    name: "ship \"X\"\n\\end",
    hp: 42,
    ratio: 1.5,
    neg: -2.25,
    pos: { x: 1.5, y: -2 },
    tags: ["a", "b", "c"],
    flags: { active: true, dead: false },
    empty_obj: {},
    empty_arr: [],
  }
  d = Labelle.json_decode(Labelle.json_encode(original))
  ok = d[:name] == original[:name]
  ok &&= d[:hp] == 42 && d[:hp].is_a?(Integer)
  ok &&= d[:ratio] == 1.5 && d[:neg] == -2.25
  ok &&= d[:pos][:x] == 1.5 && d[:pos][:y] == -2
  ok &&= d[:tags].size == 3 && d[:tags][2] == "c"
  ok &&= d[:flags][:active] == true && d[:flags][:dead] == false
  ok &&= d[:empty_obj].is_a?(Hash) && d[:empty_obj].empty?
  ok &&= d[:empty_arr].is_a?(Array) && d[:empty_arr].empty?

  # Decode-only shapes a host may hand us: whitespace everywhere, unicode
  # escapes, null fields, nested empty arrays. (Single-quoted so the \u
  # reaches the decoder as JSON text, not a ruby escape.)
  extern = Labelle.json_decode(' { "u" : "\u0041BC" , "gone" : null , "arr" : [ 1 , 2.5 , { "deep" : [ [ ] ] } ] } ')
  ok &&= extern[:u] == "ABC"
  ok &&= extern[:gone].nil?
  ok &&= extern[:arr][0] == 1 && extern[:arr][1] == 2.5
  ok &&= extern[:arr][2][:deep][0].is_a?(Array)

  # Deterministic (sorted-key) encoding is part of the codec's promise.
  ok &&= Labelle.json_encode({ b: 1, a: 2, c: 3 }) == '{"a":2,"b":1,"c":3}'
  # {} vs [] survive encode directly...
  ok &&= Labelle.json_encode({ obj: {}, arr: [] }) == '{"arr":[],"obj":{}}'

  # ...and through the host: set with both empties, get it back, set it
  # again UNTOUCHED — the byte-exact assertions live on the Zig side.
  e = Labelle::Entity.create
  e.set("Path", waypoints: [], meta: {})
  e.set("PathAgain", e.get("Path"))

  r = Labelle::Entity.create
  r.set("RoundTrip", ok: ok)
end
