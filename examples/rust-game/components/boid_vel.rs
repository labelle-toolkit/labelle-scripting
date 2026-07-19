// Boid's velocity half — the second name in scripts/swarm.rs's batch
// (see components/boid.rs; vx < vy keeps declared order == sorted ==
// stream order).
labelle::component! {
    BoidVel {
        vx: f32 = 0.0,
        vy: f32 = 0.0,
    }
}
