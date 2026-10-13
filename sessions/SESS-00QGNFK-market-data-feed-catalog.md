---
create_time: 2026-10-13T10:58:59Z
title: "Catalog of canonical market data feeds: definitions, feed ids, codecs"
summary: "Bring data-feed-core, prototypes/data-feeds-code-generator and the handrolled codecs in data-feed-definitions together into a catalog of canonical market data feeds (like market-info/assets). Missing: canonical feed id (kind id + subject id), shape as a template, all instances generated into one binary file for feed info server clients. Research done; agent proposal for declaring Databento MBP-1 (RON feed kind files of core types, kind id from provider+subject kind+semantic content, subject-free revision id, codec named by content shape, wire shape vs meaning vs view trait) awaiting the user. No decisions yet."
related_sessions:
  - SESS-00Q639F
  - SESS-00PYCE2
  - SESS-00PXT2F
agents:
  - claude-code:d32a6cdc-03e3-4c77-a3ff-e6f6b8ea89c6
  - claude-code:2e25d0d1-a48a-4ccc-8bd4-36673416f558
  - codex:01a134ec-77f7-79d2-b676-9bce6adfb5d7
---

# SESS-00QGNFK: Catalog of canonical market data feeds: definitions, feed ids, codecs

## Goal stated by the user

- Bring three things together:
  - `data-feed-core` (the core types of a data feed),
  - `prototypes/data-feeds-code-generator` (earlier work on feed definitions),
  - `data-feed-definitions/rust/crates/data-feed-definitions` (handrolled feed
    codecs).
- Build a catalog of the market data feeds, similar to how market info is
  handled (`market-info/assets`).

## What is missing, per the user

- No canonical data feed id. The handrolled demo feeds have the idea of a
  data feed kind id and a data feed subject id; together they compose the
  data feed id.
- The shape of a feed should be declared once as a template. Every feed
  instance (template + subject) is then generated into a single binary file
  that the feed info server clients read and distribute.

## Example: Databento MBP1 feed

- Known subject structure: instrument id.
- Known shape: `Mbp1BookUpdate` and `Trade`.
- Known vendor, and a known meaning for each event that comes in.
- The user wants to remove the hardcoded `pub static DATABENTO_MBO_FEED` in
  `data-feed-definitions/rust/crates/data-feed-definitions/src/demo/databento_mbo_feed.rs`
  ("disgusting") and declare the definition with the core types instead.

## Open questions

First question the user wants answered: how do we declare the definition of a
canonical feed such as the Databento MBP1 feed?

It raises these:

1. Where is the shape defined?
2. How is it defined: Rust values or some kind of DSL?
3. How does code get at a definition, or does code always rely on the data
   feed info being passed in a config?
4. How is a feed definition linked to its codec?
5. How do we tell apart the shape of the data that comes in from the
   semantic trait or view applied to that data?

## Findings (2026-10-13 research, no user input yet)

- data-feed-core has the full content model (provider, subject, events,
  messages, fields with field semantics, envelope, cadence, encodings) and
  ids `feed_`/`frev_`/`cshape_`/`mshape_`/`ffield_` (BLAKE3) plus
  `fsubj_` (`FeedSubjectId`, first 16 bytes of the subject digest). No kind
  id, no codec or view traits, no catalog or loader. serde only; every
  `*Deser` requires and re-checks the computed ids (`field_id` included).
- Core `FeedId` = provider + subject + semantic content (event kinds, message
  semantics, aggregation, semantic_revision); excludes fields and encodings.
  Core `FeedRevisionId` = provider + subject + content shape + encodings, so
  it is per subject.
- data-feed-definitions demo layer (`src/demo.rs`) does not use core
  `DataFeedDefinition` at all: `FeedKindId` = first 16 bytes of BLAKE3 over a
  name seed (`"databento_mbo"`), `FeedId` = `kind || subject` (16+16 bytes),
  `FeedRevisionId` = hash of the seed only (not content). Topic
  `feeds.{fkind}.{fsubj}.{frev}.{encoding}`; kind wildcard
  `feeds.{fkind}.*.{frev}.{encoding}` only works because frev is subject
  free. ISS-0AQP5 (open) asks for exactly this split in the core.
- `DATABENTO_MBO_FEED` is MBP-1 (name is wrong). Wire: FlatBuffers
  `DbnMdUpdate { instrument_id: u64, payload: [ubyte] }` holding one raw DBN
  v3 record; codec `data-feed-codec-dbn-0c63c4bb...` routes on DBN `rtype`,
  MBP-1 records with action Trade go to `Trade`, others to `Mbp1BookUpdate`.
  Orderand `DatabentoOrderand(u32)` = DBN `sequence`.
- View traits `Mbp1BookUpdate` and `Trade` are handwritten and provider
  neutral (`demo/traits.rs`); the per-feed traits add
  `HasFeedOrderand<Orderand = DatabentoOrderand>`.
- Codec crates are named by the kind id hex today, except DBN; DEC-0APF7 says
  one codec crate per ContentShapeId x EncodingKind. Service codecs already
  assert their crate name from a digest (`tests/crate_name.rs`).
- Consumers read compiled-in statics; only notify-gw takes `fkind_` from
  config (checked against the static). Kind ids are hardcoded in infra
  (event-bus.ts, monitoring.ts), the realtime-gateway TS dashboard
  (reimplements composition), and client-core. No feed-info checkout exists;
  the feed-info-server in infra is disabled.
- Prototype: YAML with three layers (provider wire `input_definitions`,
  normalized `content_definitions`, handwritten semantic view traits checked
  by the generator); codecs keyed by MessageShapeId/ContentShapeId; decoder
  lookup by (FeedRevisionId, encoding). Lost information on the way: provider
  `databento` became `Other`, field semantics inferred from names.
- market-info pattern: one RON file per record under `assets/`, decoded
  through constructors that recompute ids; ids in files are optional
  annotations checked by the build; ledgers + `market-info.rkyv` with a
  magic + schema-hash header.
- Core gaps hit by the DBN MBP-1 record: field id is derived from the field
  semantic, so `bid_px_00` and `ask_px_00` both tagged `Price` collide
  (`DuplicateDefinition`); scalar types have no widths (u8/u16/u32/i32/char)
  and no fixed-point scale (DBN prices are i64 x 1e-9); no way to say "one
  wire message, event chosen by the `action` field value"; no subject kind
  (only concrete `DataFeedSubject` values).

## Agent proposal (not decided)

1. Feed kind = template: provider + subject kind + content + encodings. One
   RON file per feed kind in data-feed-definitions (`assets/feed-kinds/...`),
   decoded into core types; computed ids optional annotations, like
   market-info. Rejected by the agent: Rust values (LazyLock statics again,
   unreadable from TS/catalog builder), a new DSL/YAML grammar (prototype lost
   information mapping into core types).
2. `FeedKindId` moves into data-feed-core, computed from provider + subject
   kind + semantic content (ISS-0AQP5), not a name seed. `FeedId` =
   `kind || subject`. `FeedRevisionId` computed per kind (kind + content
   shape + encodings), without the subject.
3. Wire shape = fields in the definition, hashed into ContentShapeId; codec
   crate named `data-feed-codec-{encoding}-{cshape}` and asserts it. Meaning
   = event kinds + message semantics + field semantics, hashed into the kind
   id. View trait = handwritten provider-neutral Rust/TS trait, one per message
   semantics; adapters wire -> view live in the codec crate.
4. Code compiles against generated constants of the kinds it decodes (kind
   id, revision id, content shape id); which subjects exist comes from the
   catalog binary (kinds x market-info instruments) or config at runtime.

## Decisions

None yet.

## Third-opinion review requested by the user

The user asked Codex to join the existing agents as a third opinion. Codex joined
this record and reviewed core identity/content, the generator prototype, the
handrolled DBN codec, the living data-feed reference, the accepted repository
layout, and the market-info catalog compiler pattern.

The review is in
`../../.dev-env/data/sessions/sess-00qgnfk/notebooks/feed-catalog-third-opinion.md`.
It contains recommendations and explicit open questions, not user decisions.
Key evidence for the other agents: the demo uses one MBP-1 physical record and
dispatches by action; core digest feed IDs and demo concatenated kind/subject
IDs are currently different schemes. No implementation or knowledge-base edits
were made by this review.

## Second-opinion review (Claude, second session)

Claude joined this record as the second opinion and reviewed data-feed-core
(identity, subject, content, schema), the demo feeds and the handrolled DBN
codec, the code generator prototype, the knowledge-base records (DEC-0007,
DEC-0APF7, DEC-0008, DEC-0009, DEC-0C0TX, DEC-0CAF0, ISS-0AQP5, ISS-0BJR2) and
the market-info catalog pipeline, and read the third opinion.

The review is in
`../../.dev-env/data/sessions/sess-00qgnfk/notebooks/feed-catalog-second-opinion.md`.
Recommendations, not user decisions. No code or knowledge-base edits.

Where it agrees with the third opinion:

- A subject-independent kind (template) belongs in core, with
  `FeedId = kind id || subject id` composed and split by core, replacing
  core's current provider+subject+content digest. Matches ISS-0AQP5.
- MBP-1 is one wire record; `Mbp1BookUpdate` and `Trade` are two semantic
  contracts satisfied by it, dispatched on the DBN action field.
- Instances are expanded from a coverage declaration on the kind against a
  pinned market-info revision, not from every instrument in market-info.
- First step: declare the MBP-1 kind with core types, instantiate for two real
  instruments, build the archive, keep the handrolled DBN reader.

Where it differs:

- Authoring format: Rust values in one crate per kind (ISS-0BJR2), built with
  the core constructors, not RON. A kind binds to Rust types (closed event
  enum, contract trait impls, codec type per encoding) that a file cannot name
  or check; core constructors already validate and derive the ids; there are
  about fifteen kinds, each with code; the archive is serde/rkyv output either
  way, so readers see data regardless.
- The kind id should also hash the subject kind, so per-instrument and
  per-instrument-set feeds are different kinds. Revision id belongs to the
  kind (kind id + content shape id + encodings), which the wildcard topic
  already assumes.
- Codec link is type level (`FeedCodec<Encoding> for Kind` naming the
  consumer type) and recorded in the archive as data. Two naming rules for
  codec crates: generated from our content, named by content shape id;
  handrolled for a vendor format, named by kind id. The DBN crate hash
  matches nothing today and the README rule is false for the feed codecs.
- Delete the seeds and the per-file hex pins in the same step as the kind id
  change, since every topic, Pub/Sub filter and dashboard constant changes
  anyway; replace them with a checked-in ledger the catalog build diffs.

Facts for the other agents, verified in code:

- Core feed id hashes content semantics only (event kinds, message semantics,
  cadence); revision id adds the content shape id and encodings. So core
  already has the semantic/shape split the kind id needs.
- Demo revision ids hash only the seed string, so a shape change never
  changes the revision.
- Feed codec crates are named by kind id, not content shape id; nothing tests
  those names; `data-feed-codec-dbn-0c63c4bb…` matches no id.
- No feed info server runs; every service compiles the statics in. Config
  carries kind ids only in notify-gw, validated against the statics.

Questions left for the user (also at the end of the notebook): trade record
also emits a book update or stays exclusive; subject kind in the kind id;
OHLCV as four kinds or one; who assigns the revision sequence; archive read
directly by services, by the feed info server, or both.
