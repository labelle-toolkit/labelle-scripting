// Boid's velocity half — the second name in scripts/Swarm.cs's batch (see
// components/Boid.cs; vx < vy keeps declared order == sorted == stream
// order).
[LabelleComponent]
record BoidVel
{
    public double vx = 0.0;
    public double vy = 0.0;
}
