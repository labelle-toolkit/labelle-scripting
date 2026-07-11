//! labelle_rust_scripts — the crate a rust-scripted labelle game
//! compiles its `rust/` sources into (labelle-engine#741, native family).
//!
//! Anatomy (three modules, deliberately root-declared so the repo's own
//! test crate can recompose the SAME shipped files around a different
//! game module via `#[path]` — tests/rust/src/lib.rs):
//!
//!   labelle — the Script Runtime Contract binding + the script API
//!             (`Script`, `Scripts`, safe wrappers). The game's surface.
//!   game    — THE GAME'S `rust/` DIR. This repo ships a placeholder
//!             (empty `register`); at `labelle generate` the assembler
//!             stages the game's `rust/` sources over `src/game/`, so
//!             `rust/mod.rs` is the game's crate-module root.
//!   glue    — the `labelle_rs_*` entry points the plugin Controller
//!             drives; owns the registry, the inbox drain and the
//!             panic containment. Not game-facing.
//!
//! Built as a `staticlib` by the plugin's declared build step (cargo →
//! `liblabelle_rust_scripts.a`) and linked into the game binary, where
//! the `labelle_*` contract symbols it consumes resolve against the
//! host's exports — same-binary, zero indirection, exactly like the Zig
//! side's extern declarations.

pub mod labelle;

mod game;

mod glue;
