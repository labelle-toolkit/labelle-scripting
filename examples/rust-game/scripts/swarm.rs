//! scripts/swarm.rs — the BULK-ACCESS example behavior (contract v1.3,
//! labelle-scripting#44): a 3-boid swarm integrated through the typed
//! batch iterator, `labelle::batch2::<Boid, BoidVel>(|b, v| …)` — ONE
//! `batch_get` + ONE `batch_set` per tick for the whole swarm (the
//! whole-query fast path), where per-entity `get`/`set` would cross the
//! FFI boundary 4× per boid. The RFC's guidance: reach for this shape
//! for any hot per-entity loop; rust's closure compiles, so it runs at
//! flat-loop speed.
//!
//! The `batch_view!` structs mirror the DECLARED components
//! (components/boid.rs / boid_vel.rs) field for field — the stride
//! cross-check inside `batch2` verifies that against the real host
//! stream every tick, so a drift refuses loudly instead of mis-mapping.
//!
//! The transcript pin: all values are exact in binary floating point
//! (x₀ ∈ {1,2,3}, vx = 0.5), so after 5 ticks Σx = 6 + 3×2.5 = 13.5
//! exactly and tick 5 logs `RUST_BATCH_OK_3_13.5` — count and checksum
//! prove three entities round-tripped the stream five times through the
//! REAL engine host (an engine < 2.6.0 would error here: there is no
//! batch fallback). The SUM is the pin on purpose: the engine's query
//! order is not creation order, so any single entity's value would be
//! order-dependent.

use crate::labelle::{self, Script};

labelle::batch_view! {
    Boid {
        x: f32 = 0.0,
        y: f32 = 0.0,
    }
}

labelle::batch_view! {
    BoidVel {
        vx: f32 = 0.0,
        vy: f32 = 0.0,
    }
}

#[derive(Default)]
pub struct Swarm {
    tick: u32,
}

impl Script for Swarm {
    fn init(&mut self) {
        for i in 0..3 {
            let e = labelle::create_entity();
            labelle::set_component(e, "Boid", &format!("{{\"x\":{},\"y\":0}}", i + 1));
            labelle::set_component(e, "BoidVel", "{\"vx\":0.5,\"vy\":0}");
        }
    }

    fn update(&mut self, _dt: f32) {
        self.tick += 1;
        let mut sum_x = 0.0f32;
        let n = match labelle::batch2::<Boid, BoidVel>(|b, v| {
            b.x += v.vx;
            b.y += v.vy;
            sum_x += b.x;
        }) {
            Ok(n) => n,
            Err(e) => {
                labelle::log(&format!("RUST_BATCH_ERR {}", e));
                return;
            }
        };
        if self.tick == 5 {
            labelle::log(&format!("RUST_BATCH_OK_{}_{}", n, sum_x));
        }
    }
}
