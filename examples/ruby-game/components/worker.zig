//! Tag component — the second leg of the `each("Hunger", "Worker")`
//! query in scripts/20_hunger_controller.rb (the #742 HungerController
//! shape). Deliberately still Zig: the components/ dir is
//! extension-keyed and MIXED-LANGUAGE by design — this file sits beside
//! the ruby-declared components/hunger.rb.
pub const Worker = struct {};
