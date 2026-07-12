// A GAME-SHAPED event declaration file for the cross-runner byte-parity test
// (labelle-engine#774): bare `labelle::event!{…}` / `vec2(…)`, NO `use` lines —
// what a real game events/*.rs writes; the tool injects the prelude. The
// assembler passes components/*.rs before events/*.rs, so this file is argv
// index 1 (staged decl_0001.rs) and its events sort after the component file's
// — matching emit_schema's per-kind (file, line) order. Kept byte-in-sync with
// tests/declare_cross_golden.zig's `rust_events_source`.
labelle::event! {
    hunger__feed {
        entity: u64 = 0,
        amount: f32 = 0.5,
        urgent: bool = false,
        reason: str = "why \"now\"",
        at: vec2 = vec2(-1.5, 3.0),
    }
}

labelle::event! {
    wave__spawned {}
}
