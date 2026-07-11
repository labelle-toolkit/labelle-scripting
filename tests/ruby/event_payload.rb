# event_payload.rb — the dispatch test: Labelle.on handlers must fire
# once per drained event, in FIFO order, with the payload decoded to a
# symbol-keyed Hash (nested structures included). Two handlers on one
# name prove fan-out. Findings go into the Seen component.

def init
  @state = Labelle::Entity.create
  @state.set("Seen", count: 0, fanout: 0)

  Labelle.on("cargo__delivered") do |ev|
    s = @state.get("Seen")
    s[:count] += 1
    s[:amount] = ev[:amount]
    s[:nested_ok] = (ev[:box][:w] == 2 && ev[:box][:tags][0] == "fragile")
    @state.set("Seen", s)
  end

  # Second handler on the same event: fan-out in registration order.
  Labelle.on("cargo__delivered") do |ev|
    s = @state.get("Seen")
    s[:fanout] = (s[:fanout] || 0) + 1
    @state.set("Seen", s)
  end
end
