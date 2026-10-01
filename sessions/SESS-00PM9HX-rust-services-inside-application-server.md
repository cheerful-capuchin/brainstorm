---
create_time: 2026-10-02T16:43:41Z
summary: "Constraints for new app-server services in Rust (invites CRUD as the first case): schema stays in drizzle, queries go through the egress like PgClient.query; integration design open"
related_sessions:
  - SESS-00PHDEJ
---

# SESS-00PM9HX: Rust services inside the TypeScript application server

## Context (2026-10-02)

The application server (`structure-web/packages/api`) is the only TypeScript
back-end service; the rest of the platform is Rust. The same types get
redeclared on both sides. The user does not intend to rewrite the application
server in one go, but wants the logic of *new* services written in Rust.

First case: an "invites" service, simple CRUD over the identifiers of users
invited to the platform (relates to the invitations idea in SESS-00PHDEJ).

## Constraints the user set

- New service logic lives in Rust; the existing TypeScript application server
  stays and hosts it. Not a rewrite.
- The database schema keeps being managed through drizzle
  (`structure-web/packages/app-db`), including migrations.
- Query execution must follow the existing egress model: compose a query with a
  pure builder, compile to SQL + params, submit to the egress, await the
  response, parse rows. Reference: `PgClient.query` in
  `structure-web/packages/api/src/app-db/client/client.ts`.
- HTTP stays on hono; the request may be reduced to bytes and handed to Rust.

## Open

- How the Rust code is hosted inside the Bun process (wasm vs native) and how
  it reaches the egress: no decision yet. The assistant proposed (not
  accepted): a sans-IO Rust engine component compiled to wasm like
  `application-server-core`, driven from TS by a generic step loop
  (`handle_ingress` / `drain_egress`) that forwards the component's
  `stxr.pg_client.*` egress to the existing `NodePgEgressConsumer`; a typed
  `PgValue` protobuf for params/rows encoded by node-pg column OID; sea-query
  as the pure Rust query builder; table/column identifiers generated from the
  drizzle schema into Rust; tx ids remapped by the TS adapter. Relevant
  existing facts: no Rust crate in the workspace talks to Postgres; the only
  runtime bridge today is wasm (id, application-server-core, dsl cores,
  client-core); `application-server-core::drain_egress` is still `todo!()`.
