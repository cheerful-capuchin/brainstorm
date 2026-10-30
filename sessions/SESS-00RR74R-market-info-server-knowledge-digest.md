---
create_time: 2026-10-28T10:59:36Z
title: "Market info server: contract layers, IDL direction and storage, all in one digest"
summary: "Single digest of everything on market-info-server (no new decisions): contract layers, wire vs domain types, constraints as data, own IDL (model/encoding/transport split, FlatBuffers), storage (log + folded per-product files, RAM hot set, embedded DuckDB, manifest + JetStream seq). Read this first for market info."
related_sessions:
  - SESS-00RBMHY
  - SESS-00Q639F
  - SESS-00PXT2F
  - SESS-00Q613G
  - SESS-00QGNFK
agents:
  - claude-code:47546fef-123a-48ba-86d5-074d82bf7c20
---

# SESS-00RR74R: Market info server: contract layers, IDL direction and storage, all in one digest

## How to use this record

This is the one place that collects all market-info-server design knowledge,
so a later "collect everything about market info" request can start and end
here. It holds **no new decisions**: it merges the material below, as of
2026-10-28. Everything in it is a proposal or an open question unless it says
otherwise.

Sources merged (read them only for detail this record lacks):
- SESS-00PXT2F (2026-10-07/08 sections): storage and serving at options
  scale, log/state split, per-product change lists, manifest + sequence
  numbers. That session is mostly about CME options; only its storage rounds
  are here.
- SESS-00Q639F (2026-10-09): server as the only reader of the catalog, NATS
  clients, wide wire types + constraints as data, the
  `prototypes/market-info-protocol` prototype.
- SESS-00RBMHY (2026-10-23): contract layers, Smithy-style split, CUE, text vs
  binary source.
- Transcripts behind them: claude-code e03f1def (options/storage), a564375e and
  31734df2 (layers, answers A and B, in `~/.claude/projects/-Users-doichevkostia-personal-finance/`),
  03fa3d82 (rounds 2-4).
- Knowledge base: DEC-0C0TX, DEC-07NNN, DEC-08NXH, SPEC:market-info-server,
  REF:market-info-server, ISS-0BWBN (no archive / live vs historical split).

Shareable bundle for colleagues (made 2026-10-28, same content split into
files, plus a copy of the prototype and the KB records, with brainstorm
references removed): `~/work/stxr/market-info-contract-layers/` and
`~/work/stxr/market-info-contract-layers.zip`. Not in any repo.

**Keep this record current:** when a later session decides or adds anything
about market-info-server contracts, storage or serving, add it here (or link
the newer session here) so this stays the single entry point.

State of the code on 2026-10-28: the catalog is still ~3.4k RON files in
`market-info/assets/markets` compiled into one `market-info.rkyv` (976 KB)
that every service loads whole; `market-info-server` is an unused NATS
request/reply prototype with rkyv domain types on the wire; the prototype is
uncommitted in the prototypes repo.

## Contents

1. Background: the server and its contract today
2. The layers of a service contract
3. Constraints and domain types (2026-10-09)
4. Own IDL with a Smithy-style split (2026-10-23)
5. Storage and serving behind the server (2026-10-07/08)
6. Knowledge-base records this builds on
7. Open questions

## 1. Background: the market info server and its contract today

### What the server is for

`market-info/crates/market-info-server` serves the market catalog stored in
`market-info/assets/market-info.rkyv` over NATS request/reply. It has one
operation, `ListMarketInfo`: a filter (instrument ids, venues, instrument
types), a page `limit` and an optional `cursor`, answered with a page of
`MarketInfo` and the next cursor.

### What we want from it

- **It becomes the only reader of `market-info.rkyv`.** Today many services
  load the file themselves and have to be restarted on every change.
- **Everyone can query it.** Two kinds of consumers:
  - inside the VPC, with direct NATS access: Rust services, and the
    TypeScript application server, whose core
    (`application-server-core`) runs as WASM and so cannot do any I/O;
  - outside the VPC, specifically the client (web app), which needs some kind
    of proxy or gateway.
- **A small sans-I/O client.** It only builds request bytes and parses reply
  bytes. Each service does its own I/O in whatever form suits it (async-nats
  in Rust, the NATS client in TS). The parsed markets feed `market-info-repo`.
- **The contract stays a separate crate in `market-info`.** It is not moved
  into `data-feed-definitions`. A trait per message shape that hides the
  encoding is the preferred style; FlatBuffers is the preferred encoding for
  this server (zero-copy reads).
- **Ideally, a gRPC-like service definition with our own types**, from which
  the shapes, codecs, clients and server plumbing are generated:

  ```text
  service MarketInfo {
      rpc ListMarkets(ListMarketsRequest) returns (ListMarketsResponse);
  }
  ```

- **No more hand-building per service per language**: request builders,
  encoders, reply decoders and parsers should come from the contract.
- **The server works with domain types** (`Venue`, `InstrumentId`,
  `InstrumentType`), not with transport messages.
- **The contract is stated in a form tools can check**, covering everything
  from invalid bytes to logical errors. Transport messages plus comments
  describe a contract poorly.

### Where the layers blur

The starting observation: when you look at a service from the bytes up, the
lines between concerns blur.

- There is the transport encoding.
- Then meaning is given to the bytes: these 8 bytes are a number, those 2
  bytes are two flags, those 24 bytes are a 4-byte length plus 20 characters
  of text.
- Then domain rules go on top: the number must be within bounds, the text
  must have a certain length or structure.

The Google Cloud protobuf APIs are the best example seen so far of a contract
that tries to say more than the shape, e.g. Secret Manager's
`ListSecretsRequest`:

```protobuf
message ListSecretsRequest {
  // Required. The resource name of the project ... in the format `projects/*`
  string parent = 1 [
    (google.api.field_behavior) = REQUIRED,
    (google.api.resource_reference) = {
      child_type: "secretmanager.googleapis.com/Secret"
    }
  ];

  // Optional. ... If set to 0, the server decides the number of results to
  // return. If the number is greater than 25000, it is capped at 25000.
  int32 page_size = 2 [(google.api.field_behavior) = OPTIONAL];

  string page_token = 3 [(google.api.field_behavior) = OPTIONAL];
  string filter = 4 [(google.api.field_behavior) = OPTIONAL];
}
```

Transport encoding, RPC, semantic constraints and extra annotations are all in
one place here. What those annotations actually do is covered in
part 2.

### What is wrong with the current contract

Checked against the code on 2026-10-23 and still true on 2026-10-28.

1. **The domain types are the wire format.** `market-info-server-contracts`
   is the Rust domain types (`InstrumentId`, `Venue`, `MarketInfo`) encoded
   with rkyv. Encoding, shape, value rules and meaning are fused into one Rust
   type, so the only contract is "link the same crate". Consequences:
   - a TS or Python client would have to reimplement rkyv's memory layout;
   - `Venue`'s numbering is already copied by hand into `market-info-core/ts`;
   - any field change in `MarketInfo` changes the bytes for every client at
     once.

   This is where the blurring comes from: once the domain types became the
   wire types, value rules and server-side rules had nowhere to live except
   inside the handler.

2. **Unreadable requests are dropped silently.** In
   `crates/market-info-server/src/handler.rs`, `process_message` logs a
   request that fails to decode and returns. `request_id` sits inside the
   payload, so the server cannot tell who sent it, and the client waits for
   its timeout.

3. **Every client sees every reply.** `config/config.yaml` sets one fixed
   `reply_subject`, so each client receives all replies and filters them by
   `request_id`. NATS's per-request `_INBOX` reply subject (or correlation in
   a NATS header) fixes this and item 2 together: correlation moves out of the
   payload, so even unreadable bytes can be answered with "malformed request".

4. **`limit` is clamped without telling anyone.** In
   `src/logic/list_market_info.rs`, a `limit` of 0 or anything above 100
   silently becomes 100. That is a behaviour rule the contract does not show.
   Google does the same with `page_size`, but at least writes it down.

5. **Most errors have no shape.** `InvalidCursor` is the only error. Decode
   errors and value rule errors have no form in the reply.

6. Also noted on 2026-10-09: the server keeps a `Vec<MarketInfo>` and does not
   use `market-info-repo`, and no client code exists yet.

## 2. The layers of a service contract

Two agents answered the same question in parallel ("split the contract into
layers, from invalid bytes to logical errors"). They agree on most of it and
differ in a few places, so both are kept below, followed by the differences.

### What the Google annotations actually do

`google.api.field_behavior` and `google.api.resource_reference` are protobuf
**custom options**: extra data attached to a field in the schema. protoc keeps
them in the schema descriptor it builds. They change neither the bytes on the
wire nor the code the standard generators produce. In proto3 a field marked
`REQUIRED` can still be missing on the wire.

They matter only because Google's own tools agree to read them:

- **Client generators (GAPIC)** turn `REQUIRED` fields plus
  `method_signature` into method parameters, and generate helpers for
  resource names such as `projects/{project}/secrets/{secret}` from
  `resource_reference`.
- **`api-linter`** checks the schema against Google's API design rules
  (AIP-203 for field behaviour, AIP-122/123 for resource names).
- **Docs, gcloud and Terraform** read them too.
- **The server** still has to check `REQUIRED` itself and answer
  `INVALID_ARGUMENT`. AIP-203 says the annotation is no substitute for the
  check.

`google.api` has no range or length rules at all. Buf's **protovalidate** adds
them as options holding CEL expressions, checked at runtime. The prose
"capped at 25000" on `page_size` is the part no tool sees.

So Google's split is: proto gives syntax and shape, options give
machine-readable facts, the AIP documents give the conventions behind those
facts, and the linter makes the conventions binding.

**Idea taken from this:** a contract is a schema plus structured claims that
generators, linters and tests read. A claim no tool reads is still a comment.

### Cut A: seven layers

| # | Layer | What it says | In market-info | How it fails | Who can check |
|---|---|---|---|---|---|
| 1 | Transport | How a request arrives and its reply finds the caller: subject, reply matching, size limit, timeout | request subject, fixed `reply_subject`, `request_id` | no reply, timeout | NATS client |
| 2 | Encoding | Bytes become generic values | rkyv archive | malformed bytes | generated decoder |
| 3 | Shape | Which fields, which types, optional or not, enum tags | `limit: u32`, `cursor: Option<…>` | missing field, unknown tag | generated types |
| 4 | Value rules | What a value must satisfy without knowing the server's data: ranges, lengths, patterns, cross-field rules | `limit` in 1..=100, cursor text `inst_…` | invalid argument, with the field path | generated validator, on **both** sides |
| 5 | Domain types | Checked values become types that cannot hold wrong values | `InstrumentId`, `Venue` | same as 4 | conversion code, once per domain type per language |
| 6 | Rules needing server data | Does it exist, is the caller allowed, is it still valid | cursor names an instrument still in the data | not found, failed precondition, permission | only the server |
| 7 | Behaviour | What the operation means | sorted by `InstrumentId` ascending; empty filter list means "any"; AND across fields, OR within one list; `limit` 0 becomes 100 | wrong results, no error at all | conformance tests |

Protobuf, rkyv and JSON cover layers 2-3. protovalidate, JSON Schema or
Smithy traits add layer 4. Layer 5 is where most hand work goes today.

**The dividing line is what a client can check before sending:**

- layers 2-5: the client can check them with the same generated code the
  server runs;
- layer 6: needs the server;
- layer 7: can only be shown over many calls.

**Where comments stop being enough.** Layer 7 cannot be expressed in types.
The reliable form is a set of examples stored as data: each holds a server
data fixture, a request and the expected response, and the same set runs
against every server and every client library. "Fields combine with AND"
becomes three examples plus one property test, and the comment points at
them.

**What gets generated per language from one schema file per service:**

1. wire types and codec (layers 2-3), from existing tools;
2. a validator from the value rule annotations (layer 4);
3. domain conversion (layer 5), via a custom option such as
   `(stxr.domain) = "InstrumentId"` that makes the generator call a conversion
   function provided by the domain library;
4. a client:
   `client.list_market_info(filter, limit) -> Result<Page, ListMarketInfoError>`,
   which builds the request, sets up reply matching, validates before sending
   and decodes the reply into domain types;
5. a server trait:
   `fn list_market_info(&self, query: ListMarketInfoQuery) -> Result<Page, ListMarketInfoError>`,
   receiving only checked domain values; the generated wrapper does
   decode -> validate -> convert and turns any failure into the standard error
   reply;
6. **one error envelope shared by all services**: kind (malformed, invalid
   argument, not found, failed precondition, unavailable, internal), field
   path, failed rule, retryable. Copied from `google.rpc.Status` plus
   `BadRequest.FieldViolation` (AIP-193) rather than invented.

**Cost:** a generator once per language; conversion code once per domain type
per language, shared by all services (enums such as `Venue` declared once in a
shared schema, so Rust and TS come from one definition); per service only the
handler and the conformance examples.

**Format proposed by A:** protobuf (layers 2-3), protovalidate (4), own custom
options (5), typed errors in a `oneof` (6), conformance suite (7). Reasons:
mature codecs everywhere, protoc hands plugins the full schema with options,
`buf breaking` guards schema evolution, works over NATS. Unchecked: whether
protovalidate has a usable Rust implementation.

Smithy (AWS) was named as the cleanest model/protocol split (`@range`,
`@length`, `@pattern`, `@required`, `@paginated`, error shapes; its Rust
server generator already hands handlers validated values), but any non-HTTP
protocol must be written by hand.

Keep rkyv for reading `market-info.rkyv` from disk inside Rust: the catalog is
reference data that changes rarely, so a list request gains nothing from
zero-copy.

### Cut B: eight layers

| Layer | Question it answers | Who checks | Failure class | In market-info today |
|---|---|---|---|---|
| Transport | Which bytes belong together, who asked, where to reply | framing code | dropped frame, no reply | NATS subject, `request_id` inside the payload |
| Encoding | How bytes become ints, strings, lists, variants | codec | undecodable | rkyv of the Rust type |
| Shape | Fields, cardinality, closed enums; encoding neutral | generated code, schema id | schema mismatch | not separate: the shape is the Rust struct |
| Value rules | Ranges, byte lengths, formats, item counts, "0 means unset"; no state needed | generated check, identical in every language | `InvalidRequest` with field path | limit clamped silently, nothing else checked |
| Semantics | What a value denotes: instrument id is venue specific, cursor is opaque, empty filter means all | handwritten domain type parsed at the boundary | adapter rejects | domain types are the wire types |
| Operation | State-dependent rules and promises: cursor issued by this server, pages ordered, no gaps, remaining count | server logic; property tests against a model | `InvalidCursor`; a business failure is a reply | partly in the spec, partly only in code |
| Protocol | Who sends what, in which order, how replies correlate | generated state machine | unexpected message | DEC-0C0TX, not applied here |
| Deployment | Subjects, auth, payload caps, versions | config | operational | `config.yaml` |

**Principle:** each layer fails in its own vocabulary, and the server answers
at the layer where the request failed.

**Generated per language:** codec, shape views and builders, value checks with
their constants, error types with field paths, pager for list operations,
correlation state machine. **Handwritten per language:** domain types and the
adapter from shape to domain. Business logic stays in the server.

**The cross-language answer is two language-neutral artifacts, not a
generator per language:** the contract file, and a conformance suite of byte
vectors with expected outcomes (as protobuf's conformance runner and SBE do).
A hand-written Python client is acceptable if it passes the vectors.

B also pointed at the existing prototype (`prototypes/market-info-protocol`), which
already covers the first five layers for Rust, and noted what it lacks: the
operation layer as declared patterns, a language-neutral export, and alignment
with DEC-0C0TX (which picked Rust `#[protocol]` macros and rejected a text
DSL). The two could coexist if the Rust definition exports a descriptor
manifest, as DEC-07NNN plans, and the TS generator reads the manifest.

### Where A and B differ

- **Domain conversion:** A generates it from a `(stxr.domain)` option; B and
  DEC-0C0TX keep the adapter handwritten ("semantic types are never
  generated"). Part 4 proposes a middle ground: the
  domain type is handwritten, the call into it is generated.
- **Format:** A picks protobuf plus options; B says protobuf cannot express
  message sequences or correlation and leans on the prototype / DEC-0C0TX.
- **Conformance:** A's suite is fixture + request + expected response; B's is
  byte vectors with expected outcomes. They can be one suite at two levels.

## 3. Constraints and domain types (2026-10-09)

This round came before the layer discussion and produced the prototype.

### The question: domain types on the contract, or wide types plus traits?

The service has an **input contract** (what arrives on the wire) and the
**checked message** the domain code works with:

```text
request ListMarketsRequest {
    correlation_id: u64,
    limit: u32,
    cursor: string
}
```

```rust
pub struct CorrelationId(u64);

#[derive(Copy)]
pub struct Limit(u32);
impl Limit {
    pub const UNSPECIFIED: Limit = Limit(0);
    fn or_default(&self, default: u32) -> Limit { /* ... */ }
}

pub struct Cursor(Arc<str>);

pub trait ListMarketsRequest {
    fn correlation_id(&self) -> CorrelationId;
    fn limit(&self) -> Limit;
    fn cursor(&self) -> Cursor;
}
```

The newtypes can carry more rules (`String128` that refuses more than 128
bytes, and so on).

The tension:

- putting the domain newtypes on the contract is useful, but a consumer in
  another language may not have the same validation;
- keeping the contract on wide types (`u32`, `string`) "lies" about the
  contract.

### Answer given: wide wire types, constraints as data, handwritten domain types

- **Contract fields stay language-neutral primitives, but carry declared
  constraints as data**: range, max length, required, enum set, format, the
  meaning of 0 or empty. This is what protovalidate does for protobuf. A wide
  type plus a declared rule is honest. **The lie is a rule that exists only in
  server code**, like today's silent `limit` clamp.
- **Domain newtypes and the per-message view trait stay handwritten** in the
  domain-owned contracts crate. The view trait returns newtypes.
- **Rules split in two:**
  - *structural*: expressible as data, published, checked by any consumer
    that wants to, always checked by the server;
  - *contextual*: "this cursor was issued by this server for this filter",
    defaults that come from server config. Only the domain can check these,
    and they come back as domain results (`InvalidCursor`).
- **One source per rule:** newtype constants read the generated constraint
  values; a property test checks that the shape constraint and the newtype
  constructor accept exactly the same values.
- **Zero-copy:** borrowed newtypes (`&'a str` wrappers) checked during
  adaptation, instead of `Arc<str>`.
- **Clients are not required to validate.** The server is the authority and
  must answer with a field violation instead of dropping the request.

### Which "constraints as data": SBE level, not CUE

The CME SBE template (`cme-globex/assets/templates_v13.xml`) was named as a
good model, and CUE was raised as an alternative.

**Why not CUE:** unification, disjunctions, cross-field expressions and regex
make it powerful, but there is only a Go evaluator. The WASM core, the TS
client and the Rust codecs could not all check the same rules without
reimplementing CUE. It would also be a second schema language next to the
Rust content shapes.

**Why SBE level:** SBE declares named simple types once (`String20`,
`Int32NULL`) with a closed vocabulary: primitive, length, `minValue` /
`maxValue`, `nullValue`, presence (required / optional / constant), enums,
sets, `semanticType`, `sinceVersion`. Each rule is trivial to check in any
language.

**Proposed vocabulary:** named refined types with a closed constraint set:

- range;
- byte length;
- enum membership;
- constant;
- an "unspecified" sentinel like SBE's `nullValue` (this is
  `Limit::UNSPECIFIED`);
- named formats instead of regex.

No cross-field rules at this stage (left to the domain). Each named type pairs
with the handwritten Rust newtype of the same name; its constants are
generated. Constraints are part of the shape digest. The `.fbs` file is
generated output; the protocol definition is the source.

What existed already: `data-feed-core`'s `DataFeedFieldDefinition` has a data
type, `FieldPresence` (Required / Optional / Conditional), enum variants and a
`DataFeedFieldSemantic`, but no ranges, lengths, null sentinels, constants or
named refined types. FlatBuffers schemas carry only defaults, `required` and
`deprecated`.

### How it looks in the prototype

The prototype (`prototypes/market-info-protocol`) implements this answer. The rule is
written once in `protocol/market_info.protocol`:

```text
/// How many markets a page holds. 0 asks for the server's default.
type PageLimit = u32 {
    range: 0..=100,
    unspecified: 0,
}
```

The generator turns it into constants and a check
(`crates/market-info-contracts/src/generated/constraints.rs`):

```rust
pub mod page_limit {
    pub const MIN: u32 = 0;
    pub const MAX: u32 = 100;
    /// The value that means "not set".
    pub const UNSPECIFIED: u32 = 0;

    pub fn check(value: u32) -> Result<(), ConstraintViolation> {
        check::range(value, MIN, MAX)
    }
}
```

The domain type is handwritten (`crates/market-info-contracts/src/types.rs`)
and can only be built through the generated check, via the `Refined` trait
from `protocol-runtime`:

```rust
/// A handwritten domain type paired with a named type or enum of a protocol.
/// 'a is the lifetime of the decoded buffer: string types borrow it.
pub trait Refined<'a>: Sized + Copy {
    type Wire: Copy; // u8..u64, i32, i64 or &'a str
    fn try_from_wire(wire: Self::Wire) -> Result<Self, ConstraintViolation>;
    fn wire_value(&self) -> Self::Wire;
}

pub struct PageLimit(u32);

impl PageLimit {
    pub const UNSPECIFIED: Self = Self(page_limit::UNSPECIFIED);
    pub const MAX: Self = Self(page_limit::MAX);

    pub fn or_default(self, default: PageLimit) -> PageLimit {
        if self.is_unspecified() {
            return default;
        }
        self
    }
}

impl Refined<'_> for PageLimit {
    type Wire = u32;

    fn try_from_wire(wire: u32) -> Result<Self, ConstraintViolation> {
        page_limit::check(wire)?; // [assistance] the generated check is the only way in
        Ok(Self(wire))
    }

    fn wire_value(&self) -> u32 {
        self.0
    }
}
```

`tests/generated_conformance.rs` (generated) holds a property test per named
type and an exhaustive test per enum, proving the domain type accepts exactly
the wire values the rule accepts and writes back the value it was built from.
A domain type stricter or looser than the contract fails the tests.

### Sans-I/O client shape

The client sketch that was liked:

```rust
let mut client = MarketInfoClient::new(LIST_MARKET_INFO_SUBJECT);
let mut loader = RepositoryLoader::new(&mut repository);
for _ in 0..MAX_PAGES {
    let request = client.list_request(&MarketInfoFilter::ALL, PageLimit::MAX, loader.next_cursor())?;
    // [assistance] the caller owns the I/O; here async-nats
    let reply = nats.request(request.subject.to_owned(), Bytes::copy_from_slice(request.bytes)).await?;
    client.consume_reply(&reply.payload, &mut loader)?;
    if loader.is_done() {
        break;
    }
}
```

- `OutgoingRequest<'a> { subject: &'a str, correlation_id: CorrelationId, bytes: &'a [u8] }`
  borrows the client's builder buffer (async-nats copies into `Bytes` anyway).
- The client keeps the pending correlation id and rejects replies carrying
  another one (`UnexpectedCorrelation`; the request keeps waiting).
- The loader keeps an owned cursor, because the reply buffer dies each loop
  iteration. The only copy is at repository insert.
- The server is the mirror image: `handle(request bytes) -> reply bytes`, and
  it always replies: `MalformedRequest`, `InvalidRequest { field, kind }`, or
  `InvalidCursor`.

### Prototype choices to revisit

- View traits are generated, domain types are not (DEC-0C0TX says semantic
  types are never generated; view traits return handwritten domain types).
- The codec crate is named after a BLAKE3 digest of everything that reaches
  the wire or a rule; changing a rule renames the crate and breaks consumers'
  `Cargo.toml` on purpose.
- One codec crate for both sides (DEC-0C0TX asks for one per side).
- No pluggable adapter; the cursor is the last instrument id and is not bound
  to the filter.
- Rust only, no TS emitter.
- `FieldViolation` keeps its path inline (~280 bytes) to avoid allocating.
- Field order in the `.protocol` file is the wire order, and
  `max_payload_bytes` sits in the protocol header. Both tie the model to the
  encoding and transport, which is what part 4
  separates.

## 4. The direction: our own IDL with a Smithy-style split (2026-10-23)

### The direction (not yet a decision)

- Take Smithy's idea: **decouple the contract model from the transport and
  from the encoding.**
- Use **FlatBuffers** for zero-copy reads. Tables are fine even with the
  pointer jumps.
- With AI, a custom DSL/IDL is cheap to create and change, so explore our own
  rather than adopt one as is.
- **Generate everything except the I/O.** Most generators assume HTTP; our
  services do not. The same IDL must serve the Rust engine services that talk
  over NATS, and Zenoh later.
- Define the model in the DSL, add encoding-specific rules only where needed,
  and generate Rust, TypeScript and Python types and clients. Most model
  implementations (servers) will be in Rust.

Everything below is the proposal made in response. None of it is accepted
yet.

### Four kinds of files per service

```text
*.stxr (text you write)
   │  stxr compile
   ▼
market_info.lock.json   checked in, like Cargo.lock: field ids, enum values, schema ids, model hash
compiled model (JSON)   read by everything below
   ├─▶ compatibility check against the lock on main
   ├─▶ gen rust / gen ts / gen python
   ├─▶ conformance vectors
   └─▶ docs and diagrams (the viewer)
```

#### 1. Model: `market_info.stxr`

Knows nothing about bytes or transports: named types with rules, enums,
structures, errors, operations with an interaction pattern, examples. No
subjects, no byte layout, no field numbers, no payload caps.

```text
package stxr.market_info v1

import stxr.common { Venue, InstrumentType, Decimal, Symbol }

/// How many markets a page holds.
type PageLimit = u32 {
    range: 1..=100,
    samples { valid: [1, 100], invalid: [0, 101] },
}

/// Opaque position in the catalog, issued by the server.
type MarketInfoCursor = string { bytes: 1..=64, format: ascii_graphic }

type InstrumentId = u64 { range: 1.. }

enum ListingStatus: u8, closed { Active = 1, Halted = 2, Delisted = 3 }

/// Narrows the listing. An empty list matches everything.
structure MarketInfoFilter {
    instrument_ids: list<InstrumentId> { items: 0..=256, unique },
    venues: list<Venue> { items: 0..=16, unique },
    instrument_types: list<InstrumentType> { items: 0..=8, unique },
}

structure Market {
    instrument_id: InstrumentId,
    venue: Venue,
    symbol: Symbol,
    tick_size: Decimal,
    listing_status: ListingStatus,
}

/// The cursor was not issued by this server for this filter.
error InvalidCursor { category: client }

operation ListMarketInfo {
    pattern: unary,
    traits: [readonly, idempotent],
    input {
        filter: MarketInfoFilter,
        limit: PageLimit = 100,
        cursor: optional MarketInfoCursor,
    }
    output {
        markets: list<Market> { items: 0..=100 },
        next_cursor: optional MarketInfoCursor,
        remaining_count: u64,
    }
    errors: [InvalidCursor],
    paginated { token: cursor -> next_cursor, items: markets, size: limit },
}

service MarketInfo { operations: [ListMarketInfo] }

example "one CME future per page" for ListMarketInfo {
    fixture: "two-cme-futures",
    input { filter { venues: [Cme] }, limit: 1 }
    output { markets: [{ instrument_id: 101, venue: Cme, ... }], next_cursor: "...", remaining_count: 1 }
}
```

Shared types (`Venue`, `InstrumentType`, `Decimal`) live once in a
`stxr.common` package that services import, so venue numbering has one
definition instead of the hand-kept copy in `market-info-core/ts`.

#### 2. Encoding overrides: `market_info.flatbuffers.stxr` (only when needed)

By default every structure becomes a FlatBuffers table. Field ids are
assigned on the first compile and pinned in the lock file, so nobody writes
them by hand. The file only holds exceptions:

```text
encoding flatbuffers for stxr.market_info v1 {
    struct PriceLevel           // fixed size, stored inline, can never change
    reserve Market 5            // id of a removed field, never reused
}
```

Other encodings (JSON for the web or debugging) can be further bindings of
the same model.

#### 3. Transport binding: `market_info.nats.stxr` (Zenoh next to it later)

```text
transport nats for MarketInfo {
    ListMarketInfo { subject: "stxr.market-info.v1.list", reply: inbox, timeout: 2s }
}
```

```text
transport zenoh for MarketInfo {
    ListMarketInfo { key: "stxr/market-info/v1/list", reply: query }
}
```

- The binding decides where correlation and metadata go: NATS headers or the
  per-request inbox, Zenoh attachments or the query id. **Never the payload.**
- Each subject or key carries exactly one encoding, so nobody inspects bytes
  to guess the format.
- Payload cap and default timeout live here. Because every string and list in
  the model is bounded, the generator can compute the largest possible message
  and refuse a binding whose cap is too small (e.g. a page of 100 markets that
  would exceed NATS's 1 MiB default).

#### 4. Language mapping, only for types that already exist in a domain crate

```text
map rust {
    InstrumentId = market_info_core::InstrumentId,
    Venue = market_info_core::Venue,
}
```

### How the constraints work

- **Rules sit on named types (refinement types), never on fields.** Each named
  type becomes a newtype in every language, and the only constructor runs the
  check. The prototype already does this; smithy-rs calls them "constrained
  types".
- **A small fixed list of rules, stored as data**, which each generator
  compiles to native code:
  - `range`;
  - `default` / unspecified;
  - `bytes` (UTF-8 length);
  - `items` (list length);
  - `unique`;
  - `format`: named character classes (`ascii_graphic`, `upper_alnum`,
    `decimal`), **no regex**, because regex engines in Rust, TS and Python
    differ in edge cases (Smithy's ECMA regex is a known source of
    mismatches);
  - closed or open enums.
- **Cross-field rules limited to a few structural forms:** `exactly_one_of`,
  `at_most_one_of`, `requires`, `a <= b`.
- **Escape hatch: a named check with samples.** E.g.
  `check: instrument_id_text` is written by hand in each language; the model
  carries valid and invalid samples and every implementation must pass them.
  Built-in rules carry samples too.
- **No CEL.** It needs a runtime per language, and generators cannot reason
  about arbitrary expressions.

Because rules are data, the same source also generates property-test
generators, docs, maximum message sizes, and a **breaking-change check**:
rules on requests may only widen, rules on responses may only narrow.

### Receive pipeline (Rust, zero-copy)

```text
bytes
  → transport frame       reply matching and size check, outside the payload
  → FlatBuffers verifier   offsets in bounds, required fields present, valid UTF-8
  → Verified<'a, T>
  → one constraint pass    collects violations with field paths, up to a fixed limit
  → Checked<'a, T>         handler gets view traits; accessors return checked types and can't fail
```

- Zero-copy means no allocation, not no work: the constraint pass reads every
  field once. Checking eagerly is preferred over checking on each access,
  because lazy checks would surface validation errors deep inside business
  logic.
- On the send side, builders accept only checked types, so client code cannot
  build an invalid request.

**FlatBuffers details that leak into the model:**

- **Enums are open on the wire.** The verifier lets unknown values through,
  so the check step rejects them unless the model declares the enum `open`
  (which gives an `Unknown(u8)` variant for forward compatibility).
- **Absent and default look the same**, unless the field is an optional
  scalar declared `= null`.
- **The encoding is not canonical.** One value can encode to different bytes,
  so never hash or compare FlatBuffers bytes. DEC-07NNN hashes the model
  descriptor instead, which fits.
- **Field ids must be stable**, which is why the lock file pins them.

### Domain types

The model names `InstrumentId`; the per-language mapping file says
`InstrumentId -> market_info_core::InstrumentId`.

- The generator emits a call through a conversion trait that the domain crate
  implements.
- Without a mapping, the generated refined newtype *is* the domain type.
- The samples prove the handwritten conversion agrees with the rule.

This reconciles the two cuts in part 2:
domain types stay handwritten (as DEC-0C0TX wants), the conversion call is
generated. One limit: a domain type that owns its data (`String`) costs a
copy at that point; borrowed types keep zero-copy.

### Operations and behaviour

- **Errors** are declared per operation with a category (client, state,
  server) and a retryable flag. All operations share one error envelope.
- **`paginated`** names the cursor, next cursor, items and page size, so
  generators emit a client pager and conformance cases (walking all pages
  returns the full list, no duplicates).
- **`idempotent`** allows generated clients to retry on their own.
- **`pattern`** is `unary`, `stream` or `event`. Zenoh queryables already send
  several replies per query; over NATS, `stream` needs an end-of-stream frame;
  `event` is pub/sub.
- **`examples`** hold a data fixture, an input and the expected output or
  error. They run in every language over an in-memory transport. Byte-level
  tests per binding work like Smithy's protocol tests.

### Generated vs handwritten

| Generated per language | Written once per transport per language | Written per service |
|---|---|---|
| checked types, codec, views, builders, checks, errors, pager, sans-I/O client and server dispatcher, conformance runner | I/O adapter (NATS Rust, NATS TS, Zenoh Rust) | handler, fixtures, mappings to domain types |

"Sans-I/O" means the generated code builds and reads messages but never
touches the network.

Generators are written in Rust as one binary with one backend per language,
reading the compiled JSON model, never the DSL text.

| | Model types | Codec | Checks | Client | Server |
|---|---|---|---|---|---|
| Rust | newtypes, borrowed views over FlatBuffers | FlatBuffers | constraint pass, field paths | sans-I/O | sans-I/O dispatcher + handler trait |
| TS | branded types with `parse()`, u64 as `bigint` | flatbuffers TS runtime | same rules | sans-I/O + NATS adapter | later, if needed |
| Python | frozen dataclasses that check on creation | flatbuffers Python runtime | same rules | sans-I/O + NATS adapter | later, if needed |

**Alternative:** generate only Rust and expose it to TS through WASM and to
Python through PyO3. One implementation that cannot drift, at the cost of
per-platform Python wheels, a WASM bundle in the web client, and a copy each
time data crosses the language boundary. The proposal leans towards native TS
and Python, since those generators are mostly templates and the shared
conformance vectors catch drift. Either is defensible given most logic is in
Rust.

### Why our own DSL, and not Smithy, protobuf or CUE

**Own DSL (proposed):**

- the prototype's parser already exists;
- it already refuses things Smithy allows: unbounded strings and lists,
  recursive shapes, `document`, regex;
- copy Smithy's model semantics and its trait split, and compile to a JSON
  model like Smithy's JSON AST. Generators in any language read the JSON, and
  DEC-07NNN gets a descriptor to hash.
- AI makes the grammar cheap. The lasting costs are the compatibility
  checker, clear error messages and editor support.

**Smithy itself** with custom traits and our own generators reading its JSON
AST: costs a JVM build tool, plus validators to forbid what Smithy allows.

**Protobuf + protovalidate** (cut A in 02): mature codecs and `buf breaking`,
but cannot express message sequences or correlation, and CEL rules need a
runtime per language.

**CUE** (also Pkl from Apple, Nickel in Rust): these check data inside their
own evaluator, at build or config-load time. None generates validators for
Rust or TS, and message checks must run inside each service at runtime. Only
CUE's Go evaluator is official. CUE could be the *authoring* language, with a
Go build step emitting the JSON model and a linter rejecting anything outside
the closed rule list, but that means a Go step in every build, using a tenth
of CUE, reading bounds back through CUE's Go API (`cue export` gives concrete
data, not bounds), and bindings (field ids, subjects) sit awkwardly in CUE.
Recommendation: own DSL for contracts; CUE is a good fit for **service config
files** (`config.yaml` checks before deploy), which is a separate decision.
(KDL, which also came up, is just a document format with no real constraint
support.)

### Text or binary source?

The question was whether the source could be a binary file with a viewer or
an IDE plugin, since text mostly helps agents and merges.

Proposal: **text is the source, the compiled model is the artifact.**

- **Reviews:** contract changes most need review, and GitHub can only show a
  text diff; a binary file shows as "binary file changed".
- **Merges:** two branches each adding an operation merge line by line;
  binary needs a merge driver in every tool.
- **Agents** read and edit text directly; binary needs a CLI they must be
  taught.
- **Docs and search:** doc comments sit next to definitions; grep works.
- **Tool count:** binary needs an editor, viewer, diff driver, merge driver
  and IDE plugin. Text needs the existing parser, a formatter, and later a
  language server (RustRover, Zed and VS Code can share one) and a
  tree-sitter grammar.

What binary would give is mostly id management (field numbers nobody types
or reuses). The checked-in lock file gives that while keeping text. The
viewer (HTML docs, diagrams) is generated from the compiled model.

## 5. Storage and serving behind the server (2026-10-07 and 10-08)

This came up while adding CME options to market info, two weeks before the
contract discussion. It covers what sits **behind** the market info server
(where the catalog lives, how the server boots, how readers never miss an
update), while the earlier documents cover the contract **in front** of it.

**Status: proposals only, none accepted, nothing built.** As of 2026-10-28
the catalog is still about 3.4k RON files in `market-info/assets/markets`,
compiled into one `market-info.rkyv` (under 1 MB) that services load whole.

### Why the current approach stops working

- CME's daily security definition file has about 1.08M definitions: 894k
  options, 152k futures, 31k spreads. About 167k of the options and all the
  spreads are user-defined.
- Listing rates estimated from that file: about 18k exchange-listed options
  a day (6.5M a year), about 800 futures a day, and roughly 150k user-defined
  options and spreads a day (an overestimate; most live a day or less).
- The 2010+ backfill (Databento's cut-off) comes to **at most about 100M
  exchange-listed instruments**, several hundred million with user-defined
  ones.
- Every service loads the whole catalog at startup into a fixed-size
  repository that never changes afterwards (event-gw and sim-gw cap it at
  1024 markets, the Databento jobs at 4096). The client bundles its own copy.
  None of that survives a million options.

#### Ids can stay 64-bit

Instrument ids are XXH64 hashes using all 64 bits. The chance of any
collision is about n² / 2⁶⁵:

| Number of ids | Chance of a collision |
|---|---|
| 100M | 0.03% |
| 1B | 2.7% |
| 2B | 10% |
| 5.1B | 50% |

Proposed: keep the computed u64. One registry checks every new id on insert;
a collision stops ingestion and is fixed by a salt in an override table keyed
by the identity fields. Do not catalog user-defined instruments up front;
register one when it is first traded or subscribed to. Rejected: 128-bit ids
(`DomainId`, 24 proto files, ClickHouse columns, warehouse paths and price
subjects all carry a u64) and reserving top bits for venue/type (100M ids in
56 bits is about 6.7% collision chance, much worse).

### The split: a log of changes, and the state now

The framing from our side:

- two responsibilities: the **history of changes over time** and the **state
  at the current moment**; folding all the history gives the state at any
  moment;
- a separate service stores historical market data, which is what backtests
  and replay need;
- asking for the state *now* must not mean replaying all events;
- we add our own information on top of venue definitions (presentation such
  as `display_name`);
- a query like "all ES futures since 2010" returns **snapshots**, not a
  stream of events the caller has to accumulate;
- options weighed: flat files plus snapshots, everything in RAM (fails),
  Postgres, **DuckDB on the service's ephemeral disk, rebuilt at boot**, a
  RAM/SSD tier with hot markets in RAM, RocksDB or another LSM store;
- every staff edit fires an event the history must store, so everything can
  be restored after a restart;
- every query goes through the market info server, so nobody else touches
  the storage.

### Proposal: three layers

**Fold once per instrument when events are written, not on every query.**
A contract's definition hardly changes over its life, so each instrument
keeps a short list of revisions, each valid from one time to the next. A new
revision only appears when a field actually changes. Databento sends a full
definition of every listed instrument at 00:00 UTC each weekday (about 1M
records a day), and almost all of those repeat yesterday, so the fold drops
repeats.

Rough sizes:

| | Rows | Size |
|---|---|---|
| History, 2010+ | ~100M instruments, mostly 1-2 revisions each | 15-20 GB before compression |
| Listed right now | ~1M | a few hundred MB |

So everything in RAM fails for history, but the set listed now fits easily.

#### 1. Logs: the source of truth, append only

- **Venue log:** daily and intraday Databento definitions, owned by the
  historical data service. The 2010+ backfill is just more days.
- **Staff log:** display names, curated product rules, anything we add.
  Merged with venue facts at read time, latest wins per instrument or
  product, history kept for audit. Because the merge happens at read time,
  the two logs never need a common order.

#### 2. Folded revisions: rebuildable from the logs

- A fold job (compaction) writes files to GCS, split by
  **venue / kind / product**, e.g. `cme/future/ES`, `cme/option/ES`. Each
  file holds every instrument of that product with its change list, sorted
  by instrument. Each change stores the full definition, not a diff (a
  Databento definition is full state anyway), so reading at time t is "take
  the last change at or before t".
- Parquet was proposed as the format.
- ES options today are about 18k instruments with a few changes each, so a
  few MB per file: thousands of product files instead of millions of
  instrument files. "ES futures since 2010" reads one file.
- New days land as a small extra file per product and are merged into the
  main file periodically.

#### 3. market-info-server: the only reader and writer

- **Hot set in RAM: what is listed now** (plus a few weeks after expiry, so
  positions held through expiry resolve fast). Split by **listing time, not
  popularity**: live services ask for what is listed now; backtests and
  research ask for history and can wait a little longer. This replaces a
  hand-built RAM/SSD cache.
- **Boot:** load a checkpoint of the hot set tagged with the log positions it
  covers, then replay the log after those positions. Seconds, not a replay
  of everything.
- **History through DuckDB embedded in the process**, querying the product
  partitions (Parquet). Since it is embedded, nobody else can reach it.
- **New events** (definitions, staff edits) are written to the log first,
  then applied in RAM, then compacted by the fold job. A staff edit counts as
  done only once the log has stored it; that is what lets a restart rebuild
  everything.

#### Rejected or deferred

- **Rebuilding a DuckDB file from the raw log at boot:** billions of daily
  definition records, so hours to start. Boot from folded data instead.
- **RAM/SSD tiers by popularity:** splitting by listing time gives the same
  benefit without cache logic, and cold reads are file scans anyway.
- **RocksDB or another embedded key-value store:** we would build our own
  secondary indexes (by id, by product, listed now), checkpoint upload and
  restore, and compaction tuning. That pays off with a high point-lookup
  rate, which history does not have (backtests fetch a slice once at
  startup).
- **One GCS object per instrument:** about 1M objects fetched on every boot
  of every replica (a minute or two even in parallel, growing with
  listings); GCS cannot append, so each change rewrites an object; a day's
  changes to thousands of instruments cannot land all at once; queries across
  instruments need an index built from object names; per-request overhead
  exceeds a few-hundred-byte payload.
- **Postgres:** a fine fallback (it can enforce unique ids, no custom storage
  code). Worth switching to if staff edits grow into many concurrent writers
  or need multi-record transactions. With a single writer and a log of
  record, it adds a managed database without giving much back. (An earlier
  round had proposed Postgres as the instrument store, before the log/state
  split.)

### Not missing an update while reading

The question: what if an update arrives from the market while a reader is
loading the files?

**Number every change.** One writer gives each change (market or staff) the
next sequence number and appends it to a log that can replay from a given
number. NATS JetStream fits: it numbers every message in a stream and can
deliver from any number.

**Never edit a file in place.**

- Files are write-once: a daily file per product, or a merged product file.
- A **manifest** names the files that make up the current state and the last
  sequence number they cover, S.
- The manifest swap is all-or-nothing: the writer replaces it with a GCS
  generation precondition, so readers see the old manifest or the new one,
  never half a change.
- Replaced files are deleted only after a grace period, so a reader that
  started from the old manifest can finish.

**How a reader starts:**

```text
1. read manifest            -> files f1..fn, covering changes up to S = 1_204_337
2. load f1..fn              -> meanwhile the market sends 1_204_338, 1_204_339 ...
3. follow the log from S+1  -> gets 1_204_338 onward, including what arrived during step 2
```

Two rules keep it safe: skip any number at or below the last one applied,
and if a number is missing (41 then 43), ask the log again from the last one
applied. The race only exists with plain pub/sub that cannot replay (core
NATS without JetStream); there you subscribe first, buffer, load the files,
then drop buffered changes at or below S.

**Same rule one level up.** When a strategy or executor asks the server for a
slice, the reply carries its sequence number, and the consumer follows the
server's change feed from there. Every reader at every level loads a
numbered snapshot, then follows the changes after it.

**Ingest.** A market update counts only once it is in the log. If ingest
crashes between receiving a definition and appending it, after restart it
re-reads Databento's definition replay of the week's session (`start=0`) and
drops any record equal to that instrument's last stored change, so ingesting
twice is harmless.

### Serving: slices instead of the whole catalog

- **Slices:** a service asks for venue + product or underlying + a time or
  window; the server returns it in today's archive format so existing
  decoding and repositories keep working. Slices can be cached in GCS as
  unchanging objects.
  - a strategy gets its declared instruments and option chains;
  - a backtest gets its window and records which slice it used (reproducible
    runs);
  - the Databento jobs get venue + products + day.
- **Lookup on a miss:** event-gw, sim-gw and the target executor see fills on
  instruments they did not load, so their repository must accept additions.
- **Change feed:** new intraday strikes and user-defined instruments arrive as
  events, and consumers add them.
- **Client:** searches through the server and fetches an option chain when
  needed instead of bundling the catalog.

This ties into the contract work: `ListMarketInfo` in the earlier documents
is the first of these operations, and the slice, lookup and change feed
would be further operations (unary, unary, and `event` / `stream` patterns in
part 4), each carrying the sequence number.

### Hosting caveat

A Cloud Run service's own filesystem lives in memory. Ephemeral disk is
documented only for Cloud Run jobs (BETA, at least 10 GiB). If DuckDB needs
local disk to cache Parquet, check that services support it, or run the
server on GCE like the NATS VM. Querying Parquet straight from GCS also
works, just slower for cold reads.

### Open questions from these rounds

1. Who writes the whole-venue daily definition files: the historical data
   service (a new download) or a market-info ingest job? Today's daily
   `definition` object in GCS holds only the markets we want, not the whole
   venue, and the full download is not priced.
2. Do staff edits stay as reviewed RON in git (review, but deploys), or
   become events written through the server (edits without deploys)?
3. How far back counts as hot: listed now plus how many days after expiry?
4. Are user-defined instruments left out until first used?
5. Do backtests get their catalog from the server, or keep building it from
   the replayed definitions (an earlier choice) with shared conversion code?
6. Do futures move to the same store, or stay as RON files?
7. Cloud Run service with ephemeral disk, or GCE?

## 6. Knowledge-base records this builds on

All of them live in the `knowledge-base` repo (on main) and are still
`proposed` or `draft`. Snapshot copies are in the shareable bundle.

| Record | What it says | How the discussion relates |
|---|---|---|
| DEC-0C0TX Protocol definition (`knowledge-base/docs/decisions/records/DEC-0C0TX-protocol-definition.md`) (proposed 2026-10-01) | A protocol is a domain entity separate from data feeds: two sides, message sequences (exchanges, event sequences), correlation, one generated codec crate per side and encoding. Defined in Rust with `#[protocol]` / `#[exchange]` macros. Semantic types are never generated; adapters map shapes onto domain types. A DSL with its own grammar and YAML/TOML were rejected. | **Conflicts** with the own-DSL direction in part 4. Either the DSL supersedes the macro form, or the macros export a descriptor manifest that non-Rust generators read. The protocol and deployment layers of cut B come from here. Its "handwritten adapters" rule is kept by the mapping-file proposal. |
| DEC-07NNN Canonical schema identity (`knowledge-base/docs/decisions/records/DEC-07NNN-canonical-schema-identity.md`) (proposed 2026-06-24) | `CanonicalSchemaId` = BLAKE3-256 of a deterministic, encoding-neutral descriptor graph. Encoding is a separate dimension. Envelope of `schema_id + encoding + payload`. Checked-in manifest. | **Fits.** The compiled JSON model is the descriptor graph to hash; FlatBuffers bytes are not canonical, so hashing the model is the only correct choice. The prototype names its codec crate after such a digest. |
| DEC-08NXH Market info server (`knowledge-base/docs/decisions/records/DEC-08NXH-market-info-server.md`) (proposed 2026-07-17) | The server is the source of truth for the catalog; consumers fetch it and keep a local repository; market info is loaded dynamically. Protobuf as the interim wire format, rkyv desired. Records hold `info` plus optional `presentation` (expansion). Trait-based consumer contracts, adapters at the boundary. | **Same goal** (server as the only reader). The wire format question is reopened: FlatBuffers via the own IDL instead of protobuf/rkyv. The `expand` / presentation part is not yet in the prototype. |
| SPEC: market info server (`knowledge-base/docs/specs/SPEC-market-info-server.md`) (draft, gRPC era) | Numbered behaviour rules (pagination SPEC-7.x, failures SPEC-14.x). "The protobuf types describe the transport. The market-info repository remains the source of the facts." | The behaviour layer (layer 7 in cut A) is partly written here as prose; the proposal is to turn such rules into `paginated` patterns and `examples` the generators and conformance runner read. |
| market-info-server reference (`knowledge-base/docs/references/market-info-server.md`) (living) | Current description of the server. | Background for part 1. |

Two more earlier choices the own-DSL direction would revisit:

- For the feed catalog, the choice was "Rust + macros for now, a DSL later".
- An earlier review of DEC-0C0TX accepted the Rust macro form as the way to
  define protocols.

Related principle already applied elsewhere: **one shape per subscription**.
Every NATS subject / Pub/Sub subscription carries exactly one feed and one
encoding; consumers never sniff bytes to decide how to decode. The transport
binding in part 4 follows it.

## 7. Open questions

Nothing below is settled. Where a proposal was made, it is noted. Open
questions about storage behind the server are at the end of
part 5.

### Definition form

1. **Own text DSL, Smithy, protobuf + options, or Rust `#[protocol]`
   (DEC-0C0TX)?** Current lean: own DSL compiled to a JSON model, copying
   Smithy's model/binding split. Needs an explicit decision that supersedes
   DEC-0C0TX's macro form, or a plan for the two to coexist (macros exporting
   a descriptor manifest).
2. **Lock file assigns FlatBuffers field ids, or ids written by hand in the
   encoding file?** Proposed: lock file, checked in, compared against `main`
   by the compatibility check.

### Wire vs domain

3. **Does every service get a wire shape distinct from its domain types,** or
   may Rust-only internal services keep rkyv of the domain type and accept
   that no other language can call them?
4. **Domain conversion generated or handwritten?** Proposed middle ground:
   domain types handwritten, a per-language mapping file, the generator emits
   the call; samples prove both agree.

### Behaviour

5. **`limit` outside 1..=100: reject or clamp?** Proposed: model default 100,
   reject anything outside 1..=100. Today the server clamps silently. This
   would be the first behaviour rule written into a contract.
6. **Which operation patterns do generators understand?** Candidates: list
   with keyset pagination, idempotent retries, closed expansion sets
   (presentation), unary / stream / event.
7. **Should the cursor be bound to the filter?** The prototype's cursor is the
   last instrument id and is not.
8. **Stream over NATS** needs an end-of-stream frame; Zenoh queryables give
   multiple replies natively.

### Clients and transport

9. **Client languages needed now:** Rust and TS for sure; Python?
10. **Native TS/Python generation, or Rust exposed through WASM and PyO3?**
    Proposed: native, kept in line by shared conformance vectors.
11. **Outside-VPC clients (the web client):** NATS directly, or an HTTP
    gateway in front?
12. **May trusted internal hot paths skip the constraint pass?** Proposed:
    allowed only as a deployment setting, never in the model.

### Checks to run

13. Does protovalidate have a usable Rust implementation? (Only matters if
    protobuf comes back as an option.)
14. Do the TS and Python FlatBuffers runtimes handle everything the model
    needs (optional scalars `= null`, unions, verifier limits)?

### Server fixes that hold whatever the contract form

These came out of the review of the current server and do not depend on any
of the above:

- answer undecodable requests with "malformed request" instead of dropping
  them;
- reply on the per-request NATS inbox instead of one shared reply subject;
- move correlation out of the payload (inbox or header);
- give decode and value-rule failures a reply shape (field path + rule), next
  to `InvalidCursor`.
