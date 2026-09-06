# Market-info storage plan

Date: 2026-09-06. Team: STXR Engineering. Project: market-info.
Status: proposed; implementation is not authorized by this report.
Governing input: the market-info storage discussion in this task.
Traceability: `request_backed`. No external plan dependencies.

## Outcome and scope

Maintain one hand-editable RON file per market/instrument under `market-info/assets/markets`, grouped by venue/type. Serialize the existing `MarketInfo` enum and its nested types into one rkyv snapshot, including required shared definitions. The repository owns immutable archive bytes and indexes them through market-info traits.

Requirements: **R1** editable sources; **R2** validated binary snapshot and generated CSV instrument index; **R3** reusable startup loading; **R4** retire compiled-in storage; **R5** replace snapshot and restart.

Database storage, hot reload, dynamic updates/subscriptions, Databento streaming and NATS publication are outside scope.

## Existing foundations

Workspace-relative implementation references:

- `market-info/crates/market-info-repo/src/repository.rs`: currently stores `Vec<MarketInfo>`; retain validation/indexing responsibilities while generalizing storage.
- `market-info/src/market_info.rs`: existing enum and traits; concrete serialization variants do not require concrete repository APIs.
- `market-info-core/rust/src/entities/instrument.rs`: `from_canonical_id` preserves generated identity; hashing can differ across targets.
- `data-feed-definitions`: feed contracts and codecs; no market-info rkyv codec currently exists.

Follow `dev-docs/architecture/layer-definitions.md` and `dev-docs/frameworks/engine-component-application-structure.md`; load applicable coding standards before implementation. File I/O belongs in startup infrastructure, outside domain records and handlers.

## Implementation steps

### Task 1: Prepare records — domain/infrastructure (R1)

- [ ] Parse RON into existing market records; resolve shared assets/schedules. Add rkyv support to the enum and nested types without introducing a duplicate market schema. Keep venue-specific behavior intact.
- [ ] Persist canonical IDs explicitly; Serde skipping rules do not configure rkyv. Pin ID-generation environment and archive settings. Test malformed fields, missing references and ID preservation.

### Task 2: Compile snapshots — infrastructure (R2; depends on Task 1 records)

- [ ] Define a Structure market-catalog snapshot feed. Its rkyv representation explicitly references the existing enum model; incompatible archive changes require a feed revision. Include feed reference and content digest in file framing.
- [ ] Locate the authoritative generator and verify support for this representation; `data-feed-codegen` is absent from this checkout. Do not assume automatic generation already works.
- [ ] Validate records, references and identity uniqueness, then encode deterministically. Generate Git-tracked `market-info/assets/markets/instruments.csv`: `instrument_id,venue,instrument_type,symbol,ron_path`. Use relative paths, textual IDs and venue/type/symbol ordering.
- [ ] Validate temporary outputs before replacement; preserve the previous snapshot on failure. Test reproducibility, CSV escaping, stale-index detection and CSV/snapshot agreement.

### Task 3: Load repositories — infrastructure/application (R3; depends on Task 2 format)

- [ ] Implement `file → resolve feed/codec → aligned payload → validate archive → validate catalog/build indexes → repository`. No payload consumer, adapter dispatch or handler is required.
- [ ] Make repository logic generic over storage and semantic traits. The rkyv storage owns validated immutable bytes; indexes store positions, never self-references. Accessors return borrowed archived views; no `Vec<MarketInfo>` deserialization at startup.
- [ ] Implement traits on archived types/wrappers; relax unnecessary `'static` bounds and owned-concrete accessors after checking consumers. Test lookup parity, corrupt archives, unsupported revisions and failure without partial publication.

### Task 4: Migrate consumers — composition roots (R4–R5; depends on Task 3 loader)

- [ ] Configure the snapshot path through startup YAML; report its digest. Inventory and migrate static-repository consumers before removing `StaticMktInfoRepo`.
- [ ] Document edit → compile → mount → restart and rollback to the previous snapshot. Remounting alone does not refresh memory.
- [ ] Verify changed data appears after restart and run `just fmt` and `just check` in affected projects.
