//! The query-growth pin: a result bigger than the buffers' starting
//! capacity must arrive COMPLETE — `query_into`'s required-size retry
//! (grow once, re-query) is under test, with 20-digit ids so the JSON
//! is as fat as ids get. Every assert panics (→ eviction) and the
//! verdict component never lands.

use crate::labelle::{self, EntityId, Script};

const COUNT: usize = 420;

#[derive(Default)]
pub struct BigQuery {
    ids: Vec<EntityId>,
    scratch: Vec<u8>,
}

impl Script for BigQuery {
    fn init(&mut self) {
        // Ids pre-seeded near u64 max by the Zig test: 20-digit decimals,
        // ~21 bytes per id — the full result is ~8.8 KB of JSON.
        let mut created: Vec<EntityId> = Vec::with_capacity(COUNT);
        for _ in 0..COUNT {
            let id = labelle::create_entity();
            assert!(id != 0, "create failed");
            assert!(labelle::set_component(id, "Marker", r#"{"tag":1}"#));
            created.push(id);
        }

        // Deliberately tiny starting capacity: the first sizing leg MUST
        // come back required > capacity and the wrapper must grow once.
        self.scratch = Vec::with_capacity(64);
        assert!(labelle::query_into(
            r#"["Marker"]"#,
            &mut self.ids,
            &mut self.scratch
        ));
        assert!(
            self.scratch.capacity() > 64,
            "growth premise broken — result fit 64 bytes?"
        );

        // ALL ids, each exactly once (order is not part of the contract).
        assert_eq!(self.ids.len(), COUNT, "truncated or duplicated result");
        let mut got = self.ids.clone();
        got.sort_unstable();
        created.sort_unstable();
        assert_eq!(got, created, "id set mismatch");

        // The verdict entity — the (COUNT+1)th create, asserted Zig-side.
        let verdict = labelle::create_entity();
        assert!(labelle::set_component(
            verdict,
            "BigQuery",
            &format!("{{\"count\":{}}}", self.ids.len()),
        ));
    }
}
