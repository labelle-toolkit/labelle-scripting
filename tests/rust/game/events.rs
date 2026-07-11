//! The receive side: subscribe + drain, decoded payloads, and the
//! plugin-wide inbox fanning out to EVERY live script (the suite
//! registers two instances of this struct under different component
//! names — both must see both deliveries of one tick).

use super::util;
use crate::labelle::{self, EntityId, Script};

pub struct EventCounter {
    component: &'static str,
    e: EntityId,
    count: u32,
    amount: i64,
    nested_ok: bool,
}

impl EventCounter {
    pub fn new(component: &'static str) -> EventCounter {
        EventCounter {
            component,
            e: 0,
            count: 0,
            amount: 0,
            nested_ok: false,
        }
    }

    fn write(&self) {
        labelle::set_component(
            self.e,
            self.component,
            &format!(
                "{{\"amount\":{},\"count\":{},\"nested_ok\":{}}}",
                self.amount, self.count, self.nested_ok
            ),
        );
    }
}

impl Script for EventCounter {
    fn init(&mut self) {
        self.e = labelle::create_entity();
        labelle::subscribe("cargo__delivered");
        self.write();
    }

    fn on_event(&mut self, name: &str, payload: &str) {
        if name != "cargo__delivered" {
            return;
        }
        self.count += 1;
        self.amount = util::i64_field(payload.as_bytes(), "\"amount\":").unwrap_or(-1);
        // Nested payloads arrive intact (a structural spot-check — full
        // decoding is the script's own business in slice 1).
        self.nested_ok = payload.contains("\"tags\":[\"fragile\"]");
        self.write();
    }
}
