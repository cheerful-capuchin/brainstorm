# Venue Enum Blast Radius

Date: 2026-08-17

## Scope

The probe added a temporary `Dummy` variant to
`market-info-core/rust/src/entities/venue.rs`, then ran Cargo checks through the
local workspace dependency graph. Probe-only arms were added temporarily to
downstream mappings so compilation could continue to the next dependent crate.
All probe edits were removed afterward.

The current protobuf values are `VENUE_DRIFT = 0` through `VENUE_GATE = 7`.
Any real value must be appended, not inserted or renumbered.

## Definite Compile Breaks

These files produced non-exhaustive-match errors during the dummy-variant probe.

### market-info-core

GitHub: https://github.com/stxr-prop/market-info-core

- `rust/src/entities/venue.rs:139-149` - `to_primitive`
- `rust/src/entities/venue.rs:167-181` - manual `Hash`
- `rust/src/entities/venue.rs:184-196` - `Display`

The primitive mapping is a persisted identity contract. Existing values must
remain stable. `FromStr` at `rust/src/entities/venue.rs:205-220` also requires a
new string mapping for a real venue, although it does not fail compilation from
the Rust enum-only probe.

### market-info

GitHub: https://github.com/stxr-prop/market-info

The probe reported errors in:

- `src/venue_ext.rs:19-28` - `home_currency`
- `src/venue_ext.rs:31-40` - `home_spot_asset`

### entity-core

GitHub: https://github.com/stxr-prop/entity-core

The probe reported an error in:

- `crates/entity-core/src/entities/data_feed/provider.rs:40-49` - venue semantic hash labels

### messaging

GitHub: https://github.com/stxr-prop/messaging

The probe reported an error in:

- `rust/src/conversion.rs:742-756` - domain `Venue` to protobuf `Venue`

The reverse conversion at `rust/src/conversion.rs:521-551` becomes a compile
break when the protobuf enum is updated and regenerated with the new value.

### market-info-wire

GitHub: https://github.com/stxr-prop/market-info

The probe reported an error in:

- `crates/market-info-wire/src/conversion.rs:378-390` - domain `Venue` to wire `Venue`

The reverse conversion at `crates/market-info-wire/src/conversion.rs:347-375`
becomes a compile break when the wire/protobuf enum is regenerated with the new
value.

### feed-info

GitHub: https://github.com/stxr-prop/feed-info

The probe reported an error in:

- `rust/crates/feed-info-wire/src/conversion.rs:1816-1826` - domain `Venue` to wire `Venue`

The numeric reverse path at `rust/crates/feed-info-wire/src/conversion.rs:1829-1835`
uses `try_from_primitive` and therefore needs behavior/test updates rather than
an exhaustive-match arm.

### strats_v2

GitHub: https://github.com/stxr-prop/strats_v2

The probe reported 11 errors in:

- `src/target_executor/engine_state/ready_state.rs:643`
- `src/target_executor/engine_state/ready_state.rs:726`
- `src/target_executor/target_position_manager.rs:221`
- `src/target_executor/target_position_manager.rs:266`
- `src/target_executor/target_position_manager.rs:323`
- `src/target_executor/target_position_manager.rs:357`
- `src/target_executor/target_position_manager.rs:404`
- `src/target_executor/target_position_manager.rs:437`
- `src/target_executor/target_position_manager.rs:481`
- `src/target_executor/target_position_manager.rs:503`
- `src/target_executor/venue_trade_specs.rs:595`

## Messaging And Schema Contracts

### Schema source

Repository: `messaging`

GitHub: https://github.com/stxr-prop/messaging

The canonical enum is defined in:

- `msg-schemas/proto/market-info/market_info.proto:28-37`

The new enum value must be appended with a new stable number. The enum is used
by these message schemas:

- `msg-schemas/proto/common.proto:217`
- `msg-schemas/proto/feed-info/feed_info.proto:53`
- `msg-schemas/proto/dsl-compiler/dsl_compiler.proto:65`
- `msg-schemas/proto/structure/market_info.proto:71`
- `msg-schemas/proto/market-info-server/v1/market_info_server.proto:26`
- `msg-schemas/proto/gw/uni-gw/requests.proto:63,80`
- `msg-schemas/proto/target_executor/requests.proto:83`

### Generated Rust artifacts

These must be regenerated from the `.proto` source:

- `rust/src/generated/market_info.rs:219-258`
- `rust/src/generated/market_info.serde.rs:2219-2306`
- `rust/src/generated/common.serde.rs:871-981`
- `rust/src/generated/feed_info.serde.rs:2931-3019`
- `rust/src/generated/dsl_compiler.serde.rs:1225-1308`
- `rust/src/generated/target_executor.serde.rs:934-1018`
- `rust/src/generated/gw.uni_gw.serde.rs:5172-5270,15532-15809`

Generation is controlled by `rust/build.rs:12-115`. Leaving these files stale
means Rust JSON serialization/deserialization will not recognize the new enum
name/value.

### Generated TypeScript artifacts

- `ts/generated/ts/types/market-info/market_info.ts:46-112`

The generated `venueFromJSON`/`venueToJSON` mappings must include the new value;
otherwise it is exposed as `UNRECOGNIZED` or serialized incorrectly.

### Generated Python artifacts

The embedded protobuf descriptors must be regenerated in:

- `python/messaging_py/market_info/market_info_pb2.py`
- `python/messaging_py/common_pb2.py`
- `python/messaging_py/feed_info/feed_info_pb2.py`
- `python/messaging_py/dsl_compiler/dsl_compiler_pb2.py`
- `python/messaging_py/structure/market_info_pb2.py`
- `python/messaging_py/market_info_server/v1/market_info_server_pb2.py`
- `python/messaging_py/target_executor/requests_pb2.py`
- `python/messaging_py/gw/uni_gw/requests_pb2.py`
- `python/messaging_py/gw/uni_gw/status_updates_pb2.py`

### Topic parsing

GitHub: https://github.com/stxr-prop/messaging

- `rust/src/topics.rs:600-605`

Venue topic parsing calls `Venue::from_str`. A new venue will not parse until
the domain string mapping is added.

## Compile-Safe Runtime Risks

These areas did not fail the enum-only compile probe because they use wildcards,
subset checks, or venue-specific logic. They can reject, misroute, or otherwise
mishandle a real new venue.

### event-gw

GitHub: https://github.com/stxr-prop/event-gw

- `crates/event-gw/src/trading_account_mutations.rs:177-188`

Only Drift and Hyperliquid account shapes are accepted; other venues return an
unsupported-account error.

### repos

GitHub: https://github.com/stxr-prop/repos

- `src/accounts/contracts.rs:49-57`

Only Drift is converted; other venues become `UnknownVenue`.

### application-server-client

GitHub: https://github.com/stxr-prop/application-server-client

- `rust/src/mkt_info.rs:22-31`

Only Drift and Hyperliquid convert successfully.

### structure-position-server-core

GitHub: https://github.com/stxr-prop/structure-position-server-core

- `src/load_manager.rs:13-18`

Venue handling is Drift-specific.

### dsl-btest-runtime

GitHub: https://github.com/stxr-prop/dsl-btest-runtime

- `src/exec_simulator.rs:152,424,546,613,713-716,834,916`

### dsl-runtime

GitHub: https://github.com/stxr-prop/dsl-runtime

- `crates/dsl-backtest-runtime/src/exec_simulator.rs:152,425,547,614,714-717,835,917`

Both simulators contain Drift/Hyperliquid-specific behavior.

### trade

GitHub: https://github.com/stxr-prop/trade

The probe reached a successful Cargo check for this project, so these are not
exhaustive compile breaks. They are venue-specific routing risks:

- `crates/trade/src/order/request/modify_order.rs:288-293`
- `crates/trade/src/order/request/place_order.rs:302-305`
- `crates/trade/src/order/request_dispatcher.rs:148-196,244`
- `crates/trade/src/order/msg/drift/venue_request.rs:72`
- `crates/coin-api/src/generator.rs:39-48`

### TypeScript account and API consumers

The shared TypeScript domain mirror is:

- `market-info-core/ts/src/entities/venue/venue.ts:20-27,47-57`

Venue-dependent consumers include:

- `messaging/ts/src/trading-accounts.ts:93-123`
- `entity-core/packages/entity-core/src/entities/trading_account/trading_account.ts:367-450`
- `entity-core/packages/entity-core/src/entities/delegate_account/delegate_account.ts:85-99`
- `structure-web/packages/api/src/trading-accounts/trading-accounts-http.ts`
- `structure-web/packages/api/src/trading-accounts/confirmed-accounts.ts`
- `structure-web/packages/api/src/trading-accounts/trading-accounts-service.ts`
- `structure-web/packages/client/src/trading-accounts/trading-accounts-commands.ts`

These primarily support Drift and Hyperliquid account flows. They require a
separate account/schema change if the new venue has trading accounts.

## TypeScript Venue Mirror

### market-info-core

GitHub: https://github.com/stxr-prop/market-info-core

The TypeScript mirror is:

- `ts/src/entities/venue/venue.ts:20-27,47-57`

It currently defines only `None`, `Drift`, and `Hyperliquid`, while the Rust
domain enum and protobuf enum already define eight real venues. A new TypeScript
venue must be added consistently to:

- `VENUE_ID` at `ts/src/entities/venue/venue.ts:47`
- `T` at `ts/src/entities/venue/venue.ts:48-52`
- the numeric/string ordering contract used by `id`, `display`, and parsing

The runtime assertion at `ts/src/entities/venue/venue.ts:83-87` catches a count
and string-ID mismatch, but it does not prove that the TypeScript values match
Rust or protobuf values. The TypeScript numeric IDs intentionally include
`None`, so wire conversions must preserve the documented offset.

### structure-web

GitHub: https://github.com/stxr-prop/structure-web

The verified TypeScript compile tripwire is:

- `packages/api/src/trading-accounts/trading-accounts-repository.test.ts:1095-1099`

`VENUE_ACCOUNT_FN` is typed as `Record<Venue.T, ...>`. Adding a new value to the
TypeScript mirror requires adding a corresponding fixture/account generator or
this `satisfies` check fails.

Other TypeScript consumers that require review for the new venue include:

- `packages/api/src/instruments/instruments-http.ts:78,124-132`
- `packages/api/src/instruments/instruments-repository.ts:125-147`
- `packages/api/src/trading-accounts/trading-accounts-http.ts:35-57,98-112,797-869`
- `packages/api/src/trading-accounts/trading-accounts-repository.test.ts:64,754,798,1042-1043`
- `packages/api/src/delegate-accounts/delegate-accounts-repository.test.ts:144-150`
- `packages/api/src/portfolio/portfolio-service.ts:245`
- `packages/api/src/run.ts:574-589`
- `packages/client/src/trading-accounts/trading-accounts-commands.ts:41-66,125-139`

The API schemas currently define only Drift and Hyperliquid account
representations. New venue account support needs new Zod schemas, request
mapping, response mapping, and client command handling.

### TypeScript wire mismatch

`packages/api/src/instruments/instruments-repository.ts:132` converts a wire
venue using `Venue.parsePrimitive(wire.venue + 1)`. With the current mirror
size, wire values for OKX, Binance, Bybit, Coinbase, Bitget, and Gate are
already rejected because the TypeScript mirror has no corresponding values.
Adding a new venue requires validating this offset contract against the Rust
primitive values and the protobuf values; merely appending a TypeScript value is
not sufficient if the numeric ordering differs.

### messaging TypeScript

GitHub: https://github.com/stxr-prop/messaging

The generated shared protobuf enum is:

- `ts/generated/ts/types/market-info/market_info.ts:46-112`

It must be regenerated after the `.proto` change. Its `venueFromJSON` and
`venueToJSON` functions currently enumerate only the eight protobuf values and
will otherwise return `UNRECOGNIZED` or serialize the new value incorrectly.

The separate trading-account conversion remains limited to Drift and
Hyperliquid:

- `ts/src/trading-accounts.ts:31-39,88-140`

That account oneof is a separate contract from `market_info.Venue`; it should
only be expanded when the new venue has a corresponding account model.

### TypeScript probe diagnostics

The temporary TypeScript mirror variant was checked with `just typecheck` and
`just typecheck client` in `structure-web`.

Confirmed venue-related errors:

- `packages/api/src/trading-accounts/trading-accounts-repository.test.ts:1099`
  - `VENUE_ACCOUNT_FN` is missing the new `Record<Venue.T, ...>` key.
- `../messaging/ts/src/trading-accounts.ts:139`
  - `unreachablef(account.venue, ...)` no longer accepts the expanded venue type.
- `packages/client/src/market-data/market-data-commands.ts:113`
  - The API-client venue string union is stale and rejects the new string ID.

The same checks also reported pre-existing unrelated errors in generated API
types and trading-account event fixtures; they are not attributed to the Venue
change:

- `packages/api/src/portfolio/portfolio-history-repository.ts:25`
- `packages/api/src/positions/positions-repository.ts:31`
- `packages/client/src/trading-accounts/states/running/events.test.ts:143,153`
- `packages/client/src/trading-accounts/trading-accounts-commands.ts:45,57`

The temporary TypeScript variant was removed after the probe.

## Verification Notes

Commands used:

- `cargo check` in `market-info-core`
- `cargo check --message-format=short` in `messaging`
- `cargo check --message-format=short` in `market-info`
- `cargo check --message-format=short` in `entity-core`
- `cargo check --message-format=short` in `feed-info`
- `cargo check --message-format=short` in `trade`
- `cargo check --message-format=short` in `strats_v2`
- `cargo check --message-format=short` in `event-gw`

`drift-md-server-2` could not be checked because its manifest is not included in
the root Cargo workspace and Cargo reported the existing workspace-membership
configuration error. Its venue mapping remains listed from static inspection:

- `src/engine_state.rs:110-119`

The temporary `Dummy` variant and all probe-only arms were removed after the
checks. The report is the only intentional new file.
