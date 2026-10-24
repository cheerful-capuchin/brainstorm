---
create_time: 2026-10-26T13:26:29Z
title: "Workflows on Postgres: plan and test strategy"
summary: "Plan for DEC-0D3NG (workflows Convex -> app-db Postgres, Avro payloads); user priority: testing and verification first; test strategy proposed, nothing decided yet"
related_sessions:
  - SESS-00RJW6T
agents:
  - claude-code:6c2884e8-9386-4407-8c8e-f9e2557f131d
---

# SESS-00RK705: Workflows on Postgres: plan and test strategy

## Context (2026-10-26)

User asked for a plan for DEC-0D3NG (proposed, knowledge-base PR #213, branch
`dec-workflows-postgres-avro`; see SESS-00RJW6T D3) with a heavy focus on
testing and verification: "I want to ensure that with the new database, we
don't have any issues." Asked which kinds of tests fit the workflow engine
(table, property, fuzzing, concurrency).

Facts gathered (structure-web main 6a8c6c354):

- No storage port: the engine calls 14 Convex functions in
  `packages/api/src/workflows/workflows-convex.ts` through `/v1/run`; none
  takes an expected version. The version is checked once per tick
  (`verifyWorkflowState`), later writes do `+1`.
- `api/src/test/convex.ts` `makeFakeConvex()` runs the real Convex handlers on
  a Map; `workflow-engine.test.ts` drives a whole build with a `FakeQueue`.
- Engine mixes `Date.now()` with `tp`; activity task names carry
  `tp.get_millis()` so they are not deduped.
- Fail hooks open their own transaction (`BacktestService.failRun` uses plain
  `PgClient.useTx`), so they cannot share the tick transaction yet.
- Tests: `bun test`, fast-check 4.7.0 in api and app-db (not used for
  workflows), `simulatorTest` seeded time/rng, `makeTestPgDb` = PGlite by
  default, testcontainers postgres:18 with `TEST_FEATURES=postgres`.
  PGlite is one connection, so concurrency tests need the container.
- Default isolation is Serializable; `retriedTx` retries 40001/40P01.
- `just check-app-db` runs no tests today (DEC-0D3NG Decision 3 needs it to).
- No `avro-schemas/` dir; `just export_avro_schemas` already writes
  `<fp>.avsc` files.

## Decisions

- User priority: testing and verification lead the plan.

## Open

- Assistant proposed a layered test strategy (store contract tests on an
  in-memory model and Postgres, model-based stateful property tests,
  deterministic simulation with fault injection, scripted transaction
  interleavings on real Postgres, Avro payload generation per historical
  schema, decoder and endpoint fuzzing, Quint model of the tick protocol).
  Not accepted yet.
- Assistant raised: enqueue after commit can still strand a workflow when the
  commit's acknowledgement is lost; options are a transactional outbox table
  or keeping the `expected+1` recovery. Not decided.
