# Tag component — the second leg of the `["Hunger","Worker"]` query in
# scripts/hunger.cr (the labelle-engine#742 HungerController shape, ported to
# the native family). A GAME-SHAPED zero-field `Labelle.component` declaration
# (fields hash omitted, no `require` line — the tool injects the prelude): its
# schema extracts into scripting_components.zig as an empty persistent struct.
Labelle.component "Worker"
