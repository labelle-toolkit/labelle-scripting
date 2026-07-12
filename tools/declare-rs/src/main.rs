//! labelle-declare-rs — prints the schema JSON for the rust declarations
//! compiled into it (labelle-engine#774). Exit 0, schema on stdout (one line
//! + newline), matching labelle-declare's main.zig contract.
//!
//! The `labelle` module is the SHIPPED one (native/src/labelle.rs, byte-
//! identical via #[path] — the tests/rust recomposition seam), so the macros
//! and emitter under test are exactly what a game compiles. `decls` stands
//! where the assembler stages the game's components/*.rs + events/*.rs; here
//! it is the cross-runner golden fixture.

// The probe uses only labelle's declare surface (the macros + emitter), never
// the runtime Script/Scripts/wrappers — those are the game's, dead here.
#![allow(dead_code)]

#[path = "../../../native/src/labelle.rs"]
pub mod labelle;

// The declaration structs are the runtime "prize" (typed component access); a
// game constructs them, the declare probe only registers their schemas, so the
// typed structs are deliberately never built here.
#[allow(dead_code)]
#[path = "decls.rs"]
mod decls;

fn main() {
    println!("{}", labelle::emit_schema());
}
