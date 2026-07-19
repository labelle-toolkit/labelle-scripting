// Boid's velocity half — the second name in scripts/Swarm.cs's batch (see
// components/Boid.cs; vx < vy keeps declared order == sorted == stream
// order).
// `float` fields for view alignment — see components/Boid.cs's note.
[LabelleComponent]
record BoidVel
{
    public float vx = 0.0f;
    public float vy = 0.0f;
}
