# Boid's velocity half — the second name in scripts/swarm.cr's batch
# (see components/boid.cr; vx < vy keeps declared order == sorted ==
# stream order).
Labelle.component "BoidVel", {
  vx: {f32, 0.0},
  vy: {f32, 0.0},
}
