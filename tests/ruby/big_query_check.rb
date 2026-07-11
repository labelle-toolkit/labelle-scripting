# big_query_check.rb — the query grow-and-retry path: 420 entities with
# 20-digit ids serialize to ~8.8 KB of id JSON, past the shim's 4 KiB
# initial scratch. The contract's snprintf-style return makes the
# overflow detectable and the shim must grow + retry, so Labelle.each
# yields ALL ids — a silent prefix would fail the count or the id-set
# checks below (a failed raise evicts this script and leaves BigQuery
# unset for the Zig side to catch).

N = 420

def init
  created = {}
  i = 0
  while i < N
    e = Labelle::Entity.create
    raise "mock refused entity #{i} — raise MAX_ENTITIES?" if e.nil?
    e.set("Marker", i: i)
    created[e.id] = true
    i += 1
  end

  n = 0
  Labelle.each("Marker") do |q|
    n += 1
    raise "query yielded an id that was never created" unless created[q.id]
    created.delete(q.id) # each id exactly once
  end
  raise "query must yield ALL ids after the retry, got #{n}" unless n == N
  raise "every created id must appear in the result" unless created.empty?

  r = Labelle::Entity.create
  r.set("BigQuery", count: n)
end
