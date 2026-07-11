# query_check.rb — exercises Labelle.each end to end: prelude iteration →
# raw_query shim → contract → mock host id-JSON → Entity wrappers. Writes
# its findings into a QueryResult component so the Zig test can assert on
# them without reaching into the VM.

def init
  i = 1
  while i <= 3
    e = Labelle::Entity.create
    e.set("Marker", i: i)
    e.set("Extra") if i == 2
    i += 1
  end
  Labelle::Entity.create # bare entity: must be invisible to every query

  count = 0
  sum = 0
  Labelle.each("Marker") do |e|
    count += 1
    sum += e.id
    raise "has? through the wrapper" unless e.has?("Marker")
  end

  both = 0
  Labelle.each("Marker", "Extra") do |e|
    both += 1
    raise "multi-name filter missed" unless e.get("Marker")[:i] == 2
  end

  none = 0
  Labelle.each("Nope") { |_e| none += 1 }

  r = Labelle::Entity.create
  r.set("QueryResult", count: count, sum: sum, both: both, none: none)
end
