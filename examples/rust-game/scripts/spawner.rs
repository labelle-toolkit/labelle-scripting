//! scripts/spawner.rs — the plain-script tier (rust twin of ruby-game's
//! scripts/10_spawner.rb): seeds the world in `init` and commands a
//! feeding over the engine bus on tick 2. State lives in the struct's
//! fields — the native family's isolation is the type system itself (no
//! per-script receiver tricks: two scripts are two structs).
//!
//! Each observable milestone logs ONE `RUST_<TOKEN>` line so CI can
//! `grep -oE '(RUST|ZIG)_[A-Z0-9_.]+'` and diff the exact ordered
//! sequence. This script's slice of the 5-frame timeline
//! (scripts/mod.rs's header documents the full interleaving):
//!
//!   setup   RUST_INIT              init(): Worker entity created,
//!                                   Hunger{level: 0.875} written
//!   tick 2  RUST_FEED_SENT         emit hunger__feed{entity, amount: 0.5}
//!                                   (updates run in registration order —
//!                                   spawner first — so this precedes tick
//!                                   2's RUST_LEVEL_* token; the emit
//!                                   reaches TWO subscribers off one bus:
//!                                   the native hooks/feed_watcher.zig at
//!                                   this frame's dispatchEvents, the rust
//!                                   handler on tick 3's inbox)
//!   tick 3  RUST_ENGINE_TICK_SEEN  first engine__tick arrives (emitted by
//!                                   g.tick AFTER the tick-1 drain, drained
//!                                   at tick 2's boundary, inbox-dispatched
//!                                   at tick 3 start)
//!   deinit  RUST_DEINIT            shutdown reached the spawner's deinit
//!                                   (reverse registration order — after
//!                                   the hunger system's RUST_CTRL_DONE)

use crate::labelle::{self, EntityId, Script};

#[derive(Default)]
pub struct Spawner {
    worker: EntityId,
    tick: u32,
    engine_tick_seen: bool,
}

impl Script for Spawner {
    fn init(&mut self) {
        // The worker the HungerSystem manages. 0.875 (7/8, exact in
        // binary floating point at every width en route) seeds the decay
        // chain; the component's declared default is 1.0, so the
        // read-back chain starting at 0.875 proves THIS write traveled
        // through the real ECS.
        self.worker = labelle::create_entity();
        labelle::set_component(self.worker, "Hunger", r#"{"level":0.875,"starving":false}"#);
        labelle::set_component(self.worker, "Worker", "{}");

        // Builtin-event consumption: an ENGINE event that fires every
        // frame in any game shape — proving the engine's own bus reaches
        // rust handlers through the tap. Logged once in on_event; the
        // frame number rides OUTSIDE the token so the pinned sequence
        // stays stable.
        labelle::subscribe("engine__tick");

        // Ids are u64 END TO END in rust — no bitcast (lua/ruby) or
        // BigInt (typescript) caveat; `{}` prints the true unsigned id.
        labelle::log(&format!("RUST_INIT id={}", self.worker));
    }

    fn on_event(&mut self, name: &str, payload: &str) {
        if name == "engine__tick" && !self.engine_tick_seen {
            self.engine_tick_seen = true;
            let frame = super::u64_field(payload.as_bytes(), "\"frame_number\":").unwrap_or(0);
            labelle::log(&format!("RUST_ENGINE_TICK_SEEN frame={}", frame));
        }
    }

    fn update(&mut self, _dt: f32) {
        self.tick += 1;

        // Command-as-event, CROSS-SCRIPT: this plain script commands the
        // HungerSystem (which subscribed in its init) to feed the worker.
        // The id and the exact f32 0.5 amount round-trip
        // events/hunger__feed.zig on the real engine bus; the handler
        // sees them on tick 3's inbox.
        if self.tick == 2 {
            let payload = format!("{{\"entity\":{},\"amount\":0.5}}", self.worker);
            if labelle::emit("hunger__feed", &payload) {
                labelle::log("RUST_FEED_SENT");
            } else {
                labelle::log("RUST_FEED_EMIT_FAIL");
            }
        }
    }

    fn deinit(&mut self) {
        labelle::log("RUST_DEINIT");
    }
}
