//! hunger.rs — the labelle-engine#742 HungerController pattern, ported
//! to the native family (rust twin of ruby-game's hunger_controller.rb):
//!
//!   - a plain struct implementing the `Script` trait, ALL state in its
//!     fields — no VM, no registry magic,
//!   - the buffer-reuse idiom at every contract boundary: caller-owned
//!     `Vec`s held in fields, refilled per tick by `query_into` /
//!     `get_component_into` (`clear()` retains capacity; growth is
//!     required-size-driven and happens at most once), plus a reused
//!     `String` for the write-back JSON — rust's FrameArray equivalent
//!     is exactly this clear-retains-capacity discipline, pinned flat
//!     by RUST_BUFFERS_OK at tick 5,
//!   - command-as-event feeding (`hunger__feed`, events/hunger__feed.zig)
//!     subscribed in `init` — emitted by rust/spawner.rs on tick 2, so
//!     the cross-script round-trip over the engine bus is part of the
//!     pinned transcript,
//!   - a NATIVE game-root Zig hook (hooks/feed_watcher.zig) consumes the
//!     SAME hunger__feed from the same bus — the two-layer interop.
//!
//! `Hunger` is a real engine component (components/hunger.zig) — rust
//! has no declare mode, so every call addresses it by name over the
//! contract at runtime. Timeline: mod.rs's header.

use super::{f32_field, u64_field};
use crate::labelle::{self, EntityId, Script};
use std::fmt::Write as _;

const DECAY_PER_TICK: f32 = 0.25; // exact in binary fp — see mod.rs
const STARVE_AT: f32 = 0.25;
const FEED_DEFAULT: f32 = 0.5;

#[derive(Default)]
pub struct HungerSystem {
    /// Reused across ticks — after tick 1's warm-up the steady state
    /// allocates nothing (RUST_BUFFERS_OK pins it).
    ids: Vec<EntityId>,
    scratch: Vec<u8>,
    comp: Vec<u8>,
    json_out: String,
    tick: u32,
    was_starving: bool,
    /// Capacities recorded after tick 1 (the warm-up); any later
    /// movement flips `grew` — the growth_count()==0 analog.
    warm_caps: Option<(usize, usize, usize, usize)>,
    grew: bool,
}

impl HungerSystem {
    fn caps(&self) -> (usize, usize, usize, usize) {
        (
            self.ids.capacity(),
            self.scratch.capacity(),
            self.comp.capacity(),
            self.json_out.capacity(),
        )
    }

    /// Read `level` from the freshly filled component buffer.
    fn level(&self) -> Option<f32> {
        f32_field(&self.comp, "\"level\":")
    }

    /// Whole-struct REPLACE write through the reused String (clear
    /// retains capacity — the write half of the reuse idiom).
    fn write_hunger(&mut self, id: EntityId, level: f32, starving: bool) {
        self.json_out.clear();
        let _ = write!(
            self.json_out,
            "{{\"level\":{},\"starving\":{}}}",
            level, starving
        );
        labelle::set_component(id, "Hunger", &self.json_out);
    }

    /// Same-crate public API for other rust code (the command handler
    /// below) — the ruby controller's `feed` method, verbatim story.
    fn feed(&mut self, id: EntityId, amount: f32) {
        if !labelle::get_component_into(id, "Hunger", &mut self.comp) {
            labelle::log("RUST_FEED_TARGET_MISSING");
            return;
        }
        let level = self.level().unwrap_or(0.0) + amount;
        self.write_hunger(id, level, level <= STARVE_AT);
        // Re-read AFTER the write: the token carries what actually
        // PERSISTED in the ECS, not the in-memory value.
        if labelle::get_component_into(id, "Hunger", &mut self.comp) {
            labelle::log(&format!("RUST_FED_LEVEL_{}", self.level().unwrap_or(0.0)));
        }
    }
}

impl Script for HungerSystem {
    fn init(&mut self) {
        // Size the payload buffers ONCE, with headroom: get-into growth
        // is required-size-exact, and this component's JSON changes
        // length mid-run ("starving":false → true) — headroom keeps the
        // capacity pin meaningful instead of tracking payload width.
        self.comp = Vec::with_capacity(64);
        self.json_out = String::with_capacity(64);
        labelle::subscribe("hunger__feed");
        labelle::log("RUST_CTRL_READY");
    }

    fn on_event(&mut self, name: &str, payload: &str) {
        if name != "hunger__feed" {
            return;
        }
        // Guard the payload: a malformed hunger__feed without an entity
        // has no target — exemplar code shows the guard (mirrors the
        // ruby handler's `if ev[:entity]`).
        let Some(entity) = u64_field(payload.as_bytes(), "\"entity\":") else {
            return;
        };
        let amount = f32_field(payload.as_bytes(), "\"amount\":").unwrap_or(FEED_DEFAULT);
        self.feed(entity, amount);
    }

    fn update(&mut self, _dt: f32) {
        self.tick += 1;

        // The hot-path reuse idiom: both Vecs are cleared (capacity
        // retained) and refilled by the wrapper — no per-tick list, no
        // per-read buffer.
        if !labelle::query_into(r#"["Hunger","Worker"]"#, &mut self.ids, &mut self.scratch) {
            return;
        }

        // Walk indices, not an iterator: the loop body mutably borrows
        // `self` (comp/json_out live there too).
        for i in 0..self.ids.len() {
            let id = self.ids[i];
            // get returns false when the component vanished between the
            // query and this read (entity destroyed / component removed
            // mid-tick) — guard it rather than acting on the PREVIOUS
            // iteration's stale buffer.
            if !labelle::get_component_into(id, "Hunger", &mut self.comp) {
                continue;
            }
            let level = self.level().unwrap_or(0.0) - DECAY_PER_TICK;
            let starving = level <= STARVE_AT;
            self.write_hunger(id, level, starving);

            // The token carries the written value — each tick's number
            // is only reachable through the PREVIOUS tick's persisted
            // write, so the sequence pins ECS persistence transitively.
            labelle::log(&format!("RUST_LEVEL_{}", level));

            if starving && !self.was_starving {
                self.was_starving = true;
                labelle::log("RUST_STARVING");
            }
        }

        // The growth pin: record every capacity after tick 1's warm-up;
        // ticks 2..5 must not move ANY of them (clear-retains-capacity,
        // grow-at-most-once — the whole idiom).
        if self.tick == 1 {
            self.warm_caps = Some(self.caps());
        } else if let Some(warm) = self.warm_caps {
            if self.caps() != warm {
                self.grew = true;
            }
        }
        if self.tick == 5 {
            if !self.grew && self.ids.len() == 1 {
                labelle::log("RUST_BUFFERS_OK");
            } else {
                labelle::log(&format!("RUST_BUFFERS_MOVED_SIZE_{}", self.ids.len()));
            }
        }
    }

    fn deinit(&mut self) {
        labelle::log("RUST_CTRL_DONE");
    }
}
