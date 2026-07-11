//! The u64 fidelity pin: a bit-63 entity id (0x8000000000000001 — its
//! decimal exceeds i64) must survive create → query → format EXACTLY.
//! Rust carries ids as u64 natively, so the risk isn't a VM number type
//! — it's a careless float or i64 hop in the wrapper/parse path. Every
//! id below moves through pure u64 arithmetic; the asserts panic (→
//! eviction) on any drift, and the components never land.

use crate::labelle::{self, EntityId, Script};

const BIG: EntityId = 0x8000000000000001;

#[derive(Default)]
pub struct BigId {
    ids: Vec<EntityId>,
    scratch: Vec<u8>,
}

impl Script for BigId {
    fn init(&mut self) {
        // The Zig test pre-seeds the mock's next id to BIG.
        let id = labelle::create_entity();
        assert_eq!(id, BIG, "created id drifted");
        assert!(labelle::set_component(id, "Marker", r#"{"tag":42}"#));

        // Round-trip through the query path: the id crosses host JSON
        // and the wrapper's parse — bit-exactness is the whole point.
        assert!(labelle::query_into(
            r#"["Marker"]"#,
            &mut self.ids,
            &mut self.scratch
        ));
        assert_eq!(self.ids.len(), 1, "query missed the entity");
        assert_eq!(self.ids[0], BIG, "queried id drifted");

        // Write through the QUERIED id and render it unsigned — the Zig
        // side pins both the addressed entity and the exact decimal.
        let queried = self.ids[0];
        assert!(labelle::set_component(
            queried,
            "BigId",
            &format!("{{\"idstr\":\"{}\"}}", queried),
        ));
    }
}
