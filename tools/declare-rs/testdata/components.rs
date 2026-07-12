// A GAME-SHAPED component declaration file for the cross-runner byte-parity
// test (labelle-engine#774): bare `labelle::component!{…}` and bare `vec2(…)`
// with NO `use` lines — exactly what a real game components/*.rs writes. The
// tool injects the prelude (`use crate::labelle; use crate::labelle::vec2;`),
// so if these declarations extract, the injection works. Kept byte-in-sync with
// tests/declare_cross_golden.zig's `rust_components_source`.
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

labelle::component! {
    transient Dead {}
}
