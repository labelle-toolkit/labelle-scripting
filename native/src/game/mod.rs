//! Placeholder game module — REPLACED AT GENERATE.
//!
//! In a consuming game, the assembler stages the project's `rust/` dir
//! over this directory (`src/game/`), so the game's `rust/mod.rs` is
//! this module's real body. The convention it must implement is exactly
//! one function:
//!
//! ```ignore
//! use crate::labelle::{Script, Scripts};
//!
//! pub fn register(scripts: &mut Scripts) {
//!     scripts.add("player", Box::new(Player::default()));
//! }
//! ```
//!
//! This placeholder keeps the shipped crate compiling standalone
//! (`cargo check` in the plugin repo, and the repo's own test crate
//! recomposition) — it registers nothing.

use crate::labelle::Scripts;

/// The game registration entry point. Replaced by the game's own
/// `rust/mod.rs` at generate; this placeholder registers no scripts.
pub fn register(_scripts: &mut Scripts) {}
