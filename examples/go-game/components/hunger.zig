//! The engine-side component the go scripts address by name over the
//! Script Runtime Contract (`labelle.GetComponentInto(id, "Hunger", …)`
//! in scripts/hunger.go).
//!
//! Authored in ZIG, not go — go's v1 sub-module (labelle-engine#746) is
//! demand-driven and ships NO declare tool yet, so its declared
//! components ride the pre-declare convention: a hand-written
//! `components/*.zig` struct the assembler reads into the game's
//! component registry directly (exactly how the rust example looked
//! before the native declare lane, labelle-engine#774). A
//! `tools/declare-go` extracting schemas from `components/*.go` — so a
//! go game can go 100% selected-language like ruby/rust — is the
//! documented follow-up. The go scripts still address this component by
//! name over the contract at runtime, unchanged.
//!
//! The default is deliberately NOT the 0.875 the spawner writes: the
//! decay chain starting at 0.875 proves the go-side write traveled, not
//! the declared default.
pub const Hunger = struct {
    level: f32 = 1.0,
    starving: bool = false,
};
