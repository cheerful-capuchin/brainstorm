# Market-info storage plan

Date: 2026-09-06. Team: STXR Engineering. Project: market-info.
Status: proposed; implementation is not authorized by this report.
Governing input: the market-info storage discussion in this task.
Traceability: `request_backed`. No external plan dependencies.

## Outcome and scope

Maintain one hand-editable RON file per concrete market/instrument in Git. Compile all markets and shared dependencies into one rkyv snapshot. Programs load that snapshot at startup into the ordinary market-info repository.

Requirements: **R1** editable sources; **R2** validated binary snapshot and generated CSV instrument index; **R3** reusable startup loading; **R4** retire compiled-in storage; **R5** replace snapshot and restart.

Database storage, hot reload, dynamic updates/subscriptions, Databento streaming and NATS publication are outside scope.

## Existing foundations

Workspace-relative implementation references:

- `market-info/crates/market-info-repo/src/repository.rs`: immutable owned catalog; `try_new` validates records and builds indexes.
- `market-info-core/rust/src/entities/instrument.rs`: `from_canonical_id` preserves generated identity; hashing can differ across targets.
- `market-info/crates/cme-market-info-gen`: existing canonical JSON generation.
- `market-info/crates/market-info-wire/src/bin/serialize.rs`: existing static-repository export.

Follow `dev-docs/architecture/layer-definitions.md` and `dev-docs/frameworks/engine-component-application-structure.md`; load applicable coding standards before implementation. File I/O belongs in startup infrastructure, outside domain records and handlers.

## Implementation steps

### Task 1: Define authoring records — infrastructure (R1)

- [ ] Add RON authoring support under `market-info/crates`; organize sources by venue/type, one futures contract per file. Store shared assets/schedules separately with explicit references.
- [ ] Define required fields, reference keys and unknown-field rejection. Keep generated IDs out of manual editing. Add valid examples and table tests for malformed records and missing references.

### Task 2: Compile snapshots — infrastructure (R2; depends on Task 1 records)

- [ ] Define dedicated archive records, separate from repository indexes, with schema version, source digest and canonical IDs. Pin rkyv format settings and the ID-generation environment.
- [ ] Resolve references, validate domain properties, reject duplicate identities/ID collisions, and order records deterministically. Reuse existing validation.
- [ ] Generate Git-tracked `instruments.csv` from the same validated records as the snapshot: `instrument_id,venue,instrument_type,symbol,ron_path`. Use repository-relative RON paths and sort by venue/type/symbol. Treat IDs as text. Check CSV escaping, index/snapshot agreement and stale-index detection; never edit the index manually.
- [ ] Write a temporary artifact; validate it before atomic replacement. Failure preserves the previous snapshot.
- [ ] Test reproducibility, supported market variants, canonical-ID preservation, corruption and unsupported versions; use property tests for round-trip preservation.

### Task 3: Load repositories — infrastructure/application (R3; depends on Task 2 format)

- [ ] Add a startup file loader and codec boundary. Validate archive bytes, convert to owned domain records, then call `MarketInfoRepository::try_new` through reusable catalog initialization.
- [ ] Keep file/feed resolution outside initialization logic. Test complete-catalog publication and startup failure without partial state.

### Task 4: Migrate consumers — composition roots (R4–R5; depends on Task 3 loader)

- [ ] Configure the snapshot path through startup YAML; report its digest. Inventory and migrate static-repository consumers before removing `StaticMktInfoRepo`.
- [ ] Document edit → compile → mount → restart and rollback to the previous snapshot. Remounting alone does not refresh memory.
- [ ] Verify changed data appears after restart and run `just fmt` and `just check` in affected projects.
