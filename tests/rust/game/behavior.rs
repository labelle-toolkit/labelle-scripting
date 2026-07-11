//! The POC behavior, ported to the real Script trait: the same
//! five-tick world the lua/ruby/ts suites drive (create player at the
//! origin, +10/tick, bullet + emit on tick 3, tick_started subscriber
//! reacting to n == 4) — one contract, every language, identical world.

use super::util;
use crate::labelle::{self, EntityId, Script};

#[derive(Default)]
pub struct Behavior {
    player: EntityId,
    /// Reused across ticks — steady state reads Position with zero
    /// allocation (the module's buffer-reuse idiom).
    pos_buf: Vec<u8>,
}

impl Script for Behavior {
    fn init(&mut self) {
        self.player = labelle::create_entity();
        assert!(self.player != 0, "entity_create failed");
        assert!(labelle::set_component(
            self.player,
            "Position",
            r#"{"x":0,"y":0}"#
        ));
        labelle::subscribe("tick_started");
        labelle::log(&format!("rust: player {} ready", self.player));
    }

    fn on_event(&mut self, name: &str, payload: &str) {
        if name == "tick_started" && payload.contains("\"n\":4") {
            labelle::set_component(self.player, "TickLog", r#"{"last":4}"#);
            labelle::log("rust: saw tick 4");
        }
    }

    fn update(&mut self, _dt: f32) {
        if !labelle::get_component_into(self.player, "Position", &mut self.pos_buf) {
            return;
        }
        let x = util::i64_field(&self.pos_buf, "\"x\":").unwrap_or(0) + 10;
        labelle::set_component(self.player, "Position", &format!("{{\"x\":{},\"y\":0}}", x));

        if x == 30 {
            let bullet = labelle::create_entity();
            labelle::set_component(bullet, "Bullet", r#"{"vx":0,"vy":-500}"#);
            labelle::emit("bullet_spawned", &format!("{{\"owner\":{}}}", self.player));
            labelle::log("rust: bullet away");
        }
    }
}
