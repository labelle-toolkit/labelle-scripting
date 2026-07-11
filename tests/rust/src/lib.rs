//! Test-crate root: recomposes the SHIPPED crate around the suite's
//! game module. `labelle` and `glue` are the exact files the plugin
//! ships (native/src/ — `#[path]`-included, not copied, so the code
//! under test can never drift from the code that ships); `game` is the
//! suite's scenario scripts, standing where the assembler stages a real
//! game's `rust/` dir. This is possible because native/src/lib.rs
//! declares all three modules at the CRATE ROOT and glue reaches the
//! game via `crate::game` — the same recomposition seam the assembler
//! staging uses.

#[path = "../../../native/src/labelle.rs"]
pub mod labelle;

#[path = "../game/mod.rs"]
mod game;

#[path = "../../../native/src/glue.rs"]
mod glue;
