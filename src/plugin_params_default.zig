//! Default (empty) stand-in for the assembler-staged `plugin_params`
//! module (labelle-assembler#591). build.zig wires this file under the
//! fixed `plugin_params` import name on the exported module and the test
//! modules; in a generated game the assembler's
//! `overrideImport(plugin_scripting_mod, "plugin_params", …)` REPLACES
//! it with the staged module carrying the project's resolved
//! `.params` (`language`, `sandbox`, …). Deliberately declares NOTHING:
//! consumers probe with `@hasDecl` (src/sandbox.zig) and treat absence
//! as the schema default — so an old assembler that never stages params
//! (pre-v0.83.0) gets today's behavior unchanged.
