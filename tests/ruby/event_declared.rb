# event_declared.rb — the runtime half of Labelle.event (one DSL, two
# consumers): the SAME line the declare runner reads as an event-schema
# declaration evaluates HERE to the frozen event-name string, so one
# constant drives both legs of the bus — Labelle.emit(HungerFeed, ...)
# toward the host and Labelle.on(HungerFeed) back from it. Labelle.id is
# plain 0 at runtime. Chunk-scope findings (frozen return, id value, the
# name-validation raises) fold into `ok`, reported through the Fed
# component — a false there names the failing leg via the raise below.

HungerFeed = Labelle.event "hunger__feed", entity: Labelle.id, amount: 0.5

raise "event did not return its name" unless HungerFeed == "hunger__feed"
raise "event name not frozen" unless HungerFeed.frozen?
raise "Labelle.id is not 0 at runtime" unless Labelle.id == 0

begin
  Labelle.event ""
  raise "empty event name accepted"
rescue ArgumentError => e
  raise "wrong empty-name error" unless e.message.include?("non-empty event name")
end

begin
  Labelle.event 42
  raise "non-string event name accepted"
rescue ArgumentError => e
  raise "wrong non-string error" unless e.message.include?("non-empty event name")
end

def init
  @state = Labelle::Entity.create
  @state.set("Fed", count: 0, ok: true)

  Labelle.on(HungerFeed) do |ev|
    s = @state.get("Fed")
    s[:count] += 1
    s[:amount] = ev[:amount]
    @state.set("Fed", s)
  end
end

def update(dt)
  # Emit through the constant once, toward the host (the mock captures
  # script→host emissions verbatim).
  return if @sent
  @sent = true
  Labelle.emit(HungerFeed, entity: Labelle.u64str(@state.id), amount: 0.5)
end
