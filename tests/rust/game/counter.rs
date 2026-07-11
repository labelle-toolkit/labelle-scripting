//! The bystander: advances every tick and records the dt it read
//! through `labelle::dt()` — proving the Controller's stamp reached the
//! contract before updates ran, and that siblings keep running whatever
//! the scripts around it do.

use crate::labelle::{self, EntityId, Script};

#[derive(Default)]
pub struct Counter {
    e: EntityId,
    n: u32,
}

impl Script for Counter {
    fn init(&mut self) {
        self.e = labelle::create_entity();
    }

    fn update(&mut self, dt: f32) {
        // The stamped dt and the passed dt are the same tick value.
        assert_eq!(labelle::dt(), dt, "dt stamp skew");
        self.n += 1;
        // Keys sorted (dt < n) — the suites pin component JSON
        // byte-for-byte, matching the embedded preludes' sorted encoders.
        labelle::set_component(
            self.e,
            "Counter",
            &format!("{{\"dt\":{},\"n\":{}}}", dt, self.n),
        );
    }
}
