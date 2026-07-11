//! The lifecycle port (lua/lifecycle.lua's rust twin): every remaining
//! contract seam — has/remove, prefab spawn with params, scene change
//! (rejected AND accepted arms), an emit from deinit — plus re-setup
//! semantics: `register` runs afresh, so a second setup builds fresh
//! script state against the same world.

use crate::labelle::{self, EntityId, Script};

#[derive(Default)]
pub struct Lifecycle {
    marker: EntityId,
}

impl Script for Lifecycle {
    fn init(&mut self) {
        self.marker = labelle::create_entity();
        assert!(labelle::set_component(
            self.marker,
            "Alive",
            r#"{"ok":true}"#
        ));
        assert!(labelle::component_has(self.marker, "Alive"));
        assert!(labelle::remove_component(self.marker, "Alive"));
        assert!(!labelle::component_has(self.marker, "Alive"));
        // Removes are idempotent on the component.
        assert!(labelle::remove_component(self.marker, "Alive"));

        let ship =
            labelle::spawn_prefab("ship", Some(r#"{"x":5,"y":10}"#)).expect("prefab spawn failed");
        assert!(labelle::set_component(ship, "Tag", r#"{"kind":"spawned"}"#));

        // The mock's unknown-scene arm refuses; the real one lands.
        assert!(!labelle::change_scene("nope"));
        assert!(labelle::change_scene("menu"));
    }

    fn deinit(&mut self) {
        labelle::log("rust: lifecycle deinit ran");
        labelle::emit("shutdown_done", &format!("{{\"from\":{}}}", self.marker));
    }
}
