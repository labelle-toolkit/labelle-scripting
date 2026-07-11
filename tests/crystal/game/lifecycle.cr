# The lifecycle port (rust/lifecycle.rs's crystal twin): every
# remaining contract seam — has/remove, prefab spawn with params, scene
# change (rejected AND accepted arms), an emit from deinit — plus
# re-setup semantics: `Game.register` runs afresh, so a second setup
# builds fresh script state against the same world.

class Lifecycle < Labelle::Script
  @marker : Labelle::EntityId = 0_u64

  def init : Nil
    @marker = Labelle.create_entity
    raise "set failed" unless Labelle.set_component(@marker, "Alive", %({"ok":true}))
    raise "has missed" unless Labelle.component_has(@marker, "Alive")
    raise "remove failed" unless Labelle.remove_component(@marker, "Alive")
    raise "still has" if Labelle.component_has(@marker, "Alive")
    # Removes are idempotent on the component.
    raise "re-remove failed" unless Labelle.remove_component(@marker, "Alive")

    ship = Labelle.spawn_prefab("ship", %({"x":5,"y":10}))
    raise "prefab spawn failed" unless ship
    raise "tag failed" unless Labelle.set_component(ship, "Tag", %({"kind":"spawned"}))

    # The mock's unknown-scene arm refuses; the real one lands.
    raise "bad scene accepted" if Labelle.change_scene("nope")
    raise "scene change failed" unless Labelle.change_scene("menu")
  end

  def deinit : Nil
    Labelle.log("crystal: lifecycle deinit ran")
    Labelle.emit("shutdown_done", %({"from":#{@marker}}))
  end
end
