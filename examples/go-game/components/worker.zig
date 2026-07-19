//! Tag component — the second leg of the `["Hunger","Worker"]` query in
//! scripts/hunger.go (the labelle-engine#742 HungerController shape,
//! ported to the go native family). A zero-field persistent struct;
//! Zig-authored for the same reason as components/hunger.zig (go ships
//! no declare tool in v1 — see that file's header).
pub const Worker = struct {};
