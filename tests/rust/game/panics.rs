//! The panic pins: rust's error-handling story at the FFI boundary.
//! A panic MUST NOT unwind across the C seam (instant UB / abort) —
//! the glue's catch_unwind at every entry point and around every hook
//! is what these scripts exist to trip, tick after tick.

use crate::labelle::{self, Script};

/// `update` panics every tick: logged EVERY time, never evicted (state
/// is intact — the author gets the report until it's fixed), siblings
/// unaffected. The embedded-family analog of a lua error() in update.
pub struct Exploder;

impl Script for Exploder {
    fn update(&mut self, _dt: f32) {
        panic!("boom on tick");
    }
}

/// `init` panics: the script is EVICTED — its update/deinit must never
/// run against half-initialized state. Mirrors the lua suite's
/// "a script whose init() errors is evicted from update and deinit".
pub struct BadInit;

impl Script for BadInit {
    fn init(&mut self) {
        panic!("bad_init boom");
    }

    fn update(&mut self, _dt: f32) {
        labelle::log("bad_init update ran");
    }

    fn deinit(&mut self) {
        labelle::log("bad_init deinit ran");
    }
}
