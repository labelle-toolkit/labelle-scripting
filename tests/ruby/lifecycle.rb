# lifecycle.rb — covers the hooks and contract corners no other test
# touches: deinit (observable through a log + emit, since the VM is gone
# afterwards), prefab spawning, scene changes, and component remove/has?.

def init
  @marker = Labelle::Entity.create
  @marker.set("Alive")

  # Prefab + scene, including the failure arms.
  ship = Labelle.spawn("ship", x: 5, y: 10)
  raise "spawn failed" if ship.nil?
  ship.set("Tag", kind: "spawned")
  raise "scene change refused" unless Labelle.scene_change("menu")
  raise "unknown scene accepted" if Labelle.scene_change("nope")

  # Remove is idempotent; has? flips accordingly.
  raise "expected Alive" unless @marker.has?("Alive")
  raise "remove failed" unless @marker.remove("Alive")
  raise "still Alive" if @marker.has?("Alive")
  raise "idempotent remove failed" unless @marker.remove("Alive")
end

def deinit
  Labelle.log("ruby: lifecycle deinit ran")
  Labelle.emit("shutdown_done", from: @marker.id)
end
