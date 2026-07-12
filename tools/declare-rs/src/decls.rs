//! The rust spelling of tests/declare_cross_golden.zig's ONE logical
//! declaration set — same declaration order, same field values — so the probe
//! emits the byte-identical `expected_json`. Kept byte-in-sync with the
//! golden's `rust_source` by tests/declare_rust_tool.zig's drift pin.
//!
//! Source order (the schema preserves it per kind): Kinematics (component),
//! hunger__feed (event), Dead (component), wave__spawned (event).

use crate::labelle;
use crate::labelle::vec2;

labelle::component! {
    Kinematics {
        speed: f32 = 12.5,
        accel: f32 = 1.0,
        tiny: f32 = 1e-05,
        huge: f32 = 3.4e38,
        jump_count: i32 = 3,
        min_i32: i32 = -2147483648,
        max_i32: i32 = 2147483647,
        grounded: bool = true,
        home: vec2 = vec2(-0.5, 7.0),
        label: str = "he said \"hi\"\n\ttab\\done",
        owner: u64 = 0,
    }
}

labelle::event! {
    hunger__feed {
        entity: u64 = 0,
        amount: f32 = 0.5,
        urgent: bool = false,
        reason: str = "why \"now\"",
        at: vec2 = vec2(-1.5, 3.0),
    }
}

labelle::component! {
    transient Dead {}
}

labelle::event! {
    wave__spawned {}
}
