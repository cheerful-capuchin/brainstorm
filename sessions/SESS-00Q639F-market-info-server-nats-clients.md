---
create_time: 2026-10-09T10:47:11Z
title: "Market info server as the only reader of market-info.rkyv, clients over NATS"
summary: "market-info-server as the only reader of market-info.rkyv; sans-I/O clients over NATS. Q1 answered: wide wire types + SBE-level constraints as data (not CUE), handwritten domain types. Built prototypes/market-info-protocol: protocol DSL + protocol-gen (fbs, constraints, view traits, conformance tests, FlatBuffers codec named by digest), sans-I/O client (OutgoingRequest, RepositoryLoader) and server, NATS e2e in Docker; correlation id in generated frames. No user decisions beyond building it."
related_sessions:
  - SESS-00Q613G
  - SESS-00P9RZK
  - SESS-00PXT2F
  - SESS-00PM9HX
---

# SESS-00Q639F: Market info server as the only reader of market-info.rkyv, clients over NATS

## Goal stated by the user

- market-info-server (`market-info/crates/market-info-server`) becomes the
  only reader of `market-info/assets/market-info.rkyv`. Today many services
  load the file and must restart on every change.
- Services fetch market info over NATS using
  `market-info/crates/market-info-server-contracts`.
- Two kinds of consumers: inside the VPC (Rust services and the TypeScript
  application server, whose core `application-server-core` runs as WASM with
  no I/O) and outside the VPC (the client), which needs a proxy.
- A small sans-I/O client builds request bytes and parses response bytes;
  each service does its own I/O. The parsed data feeds market-info-repo.
- Contracts stay a separate crate in market-info, not moved into
  data-feed-definitions. The user likes a trait per message shape that hides
  the encoding, and wants FlatBuffers for this server.
- Ideal: a gRPC-like service definition with our own types, from which
  content shapes, feeds and codecs are generated.

## Facts checked in the code (2026-10-09)

- Contracts today: hand-written rkyv structs carrying domain types
  (`InstrumentId`, `Venue`, `MarketInfo`); one operation `ListMarketInfo`.
- Server decodes with `rkyv::from_bytes`; an undecodable request is only
  logged, no reply. Replies go to a fixed `reply_subject`, not NATS reply
  inboxes. `limit` outside 1..=100 silently becomes 100. Cursor is an
  `InstrumentId` string; mismatch gives `InvalidCursor`.
- Server does not use market-info-repo; it keeps a `Vec<MarketInfo>`.
- No client code exists.
- Existing pattern: `data-feed-definitions/src/authentication/traits.rs` view
  traits return domain types (`Blockchain`, `Address`, `ClientId`); the
  generated codec's `adapters.rs` parses wire into them and returns
  `FieldViolation`. DEC-0C0TX: semantic types are never generated, they
  belong to the domain.

## Q1: domain types on the contract, or wide types plus traits

User's tension: domain newtypes on the contract are useful, but a consumer may
lack the same validation; wide types "lie" about the contract.

Recommendation given (not decided):
- Contract fields stay language-neutral primitives but carry declared
  constraints as data (range, max length, required, enum set, format,
  meaning of 0/empty). This is what protovalidate does for protobuf.
  Wide type plus declared constraint is not a lie; the lie is a rule that
  exists only in server code (today's silent limit clamp).
- Domain newtypes and the per-message view trait stay hand-written in the
  domain-owned contracts crate; the view trait returns newtypes.
- Rules split in two: structural (expressible as data, published, checked by
  any consumer that wants to, always checked by the server) and contextual
  (cursor issued by this server for this filter, defaults from server config)
  which only the domain can check and which surface as domain results
  (`InvalidCursor`).
- One source per rule: newtype constants read the generated constraint
  values; a property test checks shape constraint and newtype constructor
  accept the same values.
- Zero copy: borrowed newtypes (`&'a str` wrappers) validated in `adapt`
  rather than `Arc<str>`.
- Clients are not required to validate; server is the authority and must
  reply with a field violation instead of dropping the request.

### Follow-up: CUE or SBE for constraints as data

User asked whether "constraints as data" means something like CUE, and named
the CME SBE template (`cme-globex/assets/templates_v13.xml`) as a good model.

Facts: data-feed-core `DataFeedFieldDefinition` already has data type,
`FieldPresence` (Required/Optional/Conditional), enum variants and a
`DataFeedFieldSemantic`; scalars are Bool/I64/U64/F64/Decimal/Timestamp/
String/Bytes. No ranges, lengths, null sentinels, constants or named
refined types. FlatBuffers schemas carry only defaults/required/deprecated.

Recommendation given (not decided): SBE level, not CUE.
- CUE: unification, disjunctions, cross-field expressions, regex; Go
  evaluator only, so the WASM core, the TS client and Rust codecs cannot all
  check the same rules without reimplementing CUE; a second schema language
  beside the Rust content shapes.
- SBE: named simple types declared once (`String20`, `Int32NULL`) with a
  closed vocabulary (primitive, length, minValue/maxValue, nullValue,
  presence required/optional/constant, enums, sets, semanticType,
  sinceVersion). Each rule is trivial to check in any language.
- Proposed: add named refined types to content shapes with a closed
  constraint set (range, byte length, enum membership, constant, an
  "unspecified" sentinel like SBE nullValue, which is the user's
  `Limit::UNSPECIFIED`); named formats instead of regex; no cross-field
  rules (domain). Named type pairs with the handwritten Rust newtype of the
  same name; constants generated. Constraints are part of the shape digest.
  `.fbs` is generated output, the content shape is the source.

### Follow-up: sketch of the definition and the generated Rust codec

User asked what the definition and generated codec would look like, Rust
clients only for now. Sketch given (not decided):

- Handwritten in market-info-server-contracts: constraint constants
  (`PAGE_LIMIT_MAX`), named type statics built from them, content shapes,
  `MARKET_INFO_SERVICE: ServiceDefinition`; domain newtypes (`PageLimit`,
  borrowed `MarketInfoCursor<'a>`, `CorrelationId`) implementing a
  `Refined` trait (`try_from_wire`, `to_wire`); view and handler traits.
  Constants shared by definition and newtype avoid a crate cycle (the codec
  depends on contracts, not the other way).
- Generated `content-shape-codec-flatbuffers-<hex>`: `.fbs` + flatc output,
  `adapters.rs` (verified root, then `Refined::try_from_wire` per field,
  `FieldViolation` with static field and message), `codec.rs`
  (`consume_*` decode -> adapt -> handle, reply dispatch on page vs
  rejected), `producer.rs` (encode any view into a reused
  `FlatBufferBuilder`), and a generated property test that each newtype
  accepts exactly what its named type definition accepts.
- Sans-I/O client (handwritten, separate small crate): correlation ids,
  builds request bytes, consumes replies into a handler; a repository loader
  handler inserts markets into market-info-repo; caller loops on
  `next_cursor`. Copy happens only at repository insert.
- Server changes implied: reply to the NATS reply inbox instead of a fixed
  `reply_subject` (every client would see every reply), answer bad
  requests with a rejection instead of only logging.
- Open: reply framing (FlatBuffers union per method vs DEC-0C0TX header);
  where the generator runs and where the codec crate lives (market-info vs
  data-feed-definitions/codecs); how the generator finds the Rust path of
  each named type.

### Follow-up: OutgoingRequest and the authentication protocol

User likes the `MarketInfoClient` sketch (list_request -> OutgoingRequest,
consume_reply into a handler, service loops on the cursor and does NATS
I/O itself). Not yet a decision on the rest.

- `OutgoingRequest<'a>` explained as an invented type: `{ subject: &'a str,
  correlation_id: CorrelationId, bytes: &'a [u8] }`, bytes borrow the
  client's builder; async-nats copies into `Bytes` anyway. Client keeps the
  pending correlation id and rejects replies for another one. Loader keeps
  an owned cursor because the reply buffer dies each loop iteration.
- Authentication protocol facts: `data-feed-definitions` commit 95d4d47
  (2026-09-28) added `authentication/` (shapes, `AUTHENTICATION_SERVICE`,
  view/handler traits) and the Rust codec crate
  `content-shape-codec-protobuf-e277d443...`. The codec is written by hand,
  no generator exists; `tests/crate_name.rs` pins the crate name to
  `codec_hex()`. No Rust crate outside data-feed-definitions depends on it.
  structure-web `packages/api` uses the TS package of an older digest
  (`b92bd326...`) from git.

### Prototype built: `prototypes/market-info-protocol` (2026-10-09)

User asked to build the client sketch in the prototypes repo, ideally with
a DSL describing messages and constraints. Built (uncommitted), all checks
green (`just check`: generated files in sync, fmt, clippy -D warnings,
tests; `just e2e`: client + server over NATS 2.11.3 in Docker).

- DSL `protocol/market_info.protocol`: `protocol <path> { max_payload_bytes }`,
  `type X = base { range | unspecified | bytes | format }`, `enum X: u8|u16`,
  `message`, `union`, `service { rpc M(Req) returns Res errors Err; }`.
  Closed constraint set; formats `ascii_graphic | upper_alnum | decimal`
  (no regex); list fields need `items: a..=b`; raw strings rejected;
  declare-before-use (no recursion); depth <= 8; enum 0 reserved.
- `protocol-dsl` (lexer, parser, validate, digest, emitters, `protocol-gen`
  CLI with `--check`): emits `.fbs` (flatc 25.12.19 produces tables),
  contracts `generated/constraints.rs` + `views.rs` +
  `tests/generated_conformance.rs`, codec crate
  `content-shape-codec-flatbuffers-<blake3 hex>` (adapters, codec, producer).
- Correlation id moved out of messages into generated per-method frames
  (`<Rpc>RequestFrame`, `<Rpc>ReplyBody` union, `<Rpc>ReplyFrame`).
- Domain types handwritten (`Refined` trait: `try_from_wire`, `wire_value`)
  and built only through generated checks; conformance proptests prove
  equality with the rule. View traits are generated (deviation from
  DEC-0C0TX noted in the README).
- Zero copy, zero allocation parse: views borrow the payload, lists in
  ArrayVec sized by `items`; verifier depth/table limits computed from
  the protocol. Producer refuses list overflow and oversized payloads.
- `market-info-client`: `MarketInfoClient`, `OutgoingRequest`,
  correlation guard (unspecified id accepted only on rejections),
  `RepositoryLoader`, in-memory repository stand-in for market-info-repo.
- `market-info-server`: sans-I/O `handle(bytes) -> bytes`, always replies
  (MalformedRequest / InvalidRequest{field path, kind} / InvalidCursor).
- Prototype choices to revisit: one codec crate for both sides, no
  pluggable adapter, cursor not bound to the filter, Rust only (no TS
  emitter), FieldViolation inline path (~280 B; clippy size lints allowed).
