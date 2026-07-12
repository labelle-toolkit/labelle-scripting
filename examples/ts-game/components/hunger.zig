//! The engine-side component the typescript scripts address by name over
//! the Script Runtime Contract (`e.get("Hunger", h)` in
//! scripts/20_hunger_controller.ts). TypeScript has no declare mode
//! (`DECLARE_RUNNERS` is lua+ruby — and a `components/*.ts` is a pointed
//! generate error), so the component is a real `components/*.zig` file:
//! the rust-game shape. What typescript adds on top is the OPPOSITE
//! direction: at `labelle generate` the assembler parses THIS struct into
//! the generated `labelle-components.d.ts` (`"Hunger": { level: number;
//! starving: boolean }`), so every script-side access to it is
//! TYPE-CHECKED — a typo'd field access is a TS2551/TS2339 before
//! anything builds (CI's negative test pins it).
//!
//! The default is deliberately NOT the 0.875 the spawner writes: the
//! decay chain starting at 0.875 proves the typescript-side typed write
//! traveled, not the declared default.
pub const Hunger = struct {
    level: f32 = 1.0,
    starving: bool = false,
};
