# Design: `program-events.json` for logger2, and alert policies from it

Status: proposed (2026-10-12), read-only design by an agent; decisions open.
Session: SESS-00QE2QN.

## 0. What the code does today

- `logger2-macros/src/lib.rs` parses `context, LitStr, args`, parses the
  literal at compile time (`format_parser::parse_format_string`) and already
  emits per-call-site statics (`__PLACEHOLDERS`, `__NAMED_ARG_KEYS`).
- `LOG_LEVEL` is read at macro expansion: a level below it expands to
  `let _ = &ctx; let _ = &arg;`, so compiled-in call sites depend on the
  build environment.
- Text rendering (`transit.rs:287`): `[LEVEL]`, optional ` [k=v, k=v]`
  context, space, message. Levels: `DEBUG INFO NOTICE WARN ERROR CRIT ALERT
  EMERG`. `StdoutWriter` -> Cloud Run `textPayload` like
  `[ERROR] download_job.overdue dataset=...`; text lines carry no GCP
  severity (DEFAULT; to confirm).
- `GCPLogSink` (`backend/sink.rs`) writes JSON with a real `severity`
  (1:1 for all 8 levels).
- Download job: `sinks!(StdoutWriter)`; three alerted sites use
  `log_error!` with `{}` for the name from `AlertedEvent`
  (`run.rs:416`, `resolve.rs:398`, `main.rs:288`);
  `download_job.dataset.done` is logged from two sites.
- `logger2-backend/src/event_conversion.rs` takes `EventLog.event` from a
  runtime context key `event`; `dev-docs/code-standards/observability-events.md`
  calls one event name at several sites an anti-pattern.
- Survey of ~340 call sites: ~77% start with a dotted snake_case name, ~17%
  near misses (trailing `:`, hyphens like `sim-gw.`), ~2% start with `{}`,
  ~4% prose. No repo uses `log_alert!`/`log_emergency!`.
- wasm: `engine` checks `wasm32-unknown-unknown` with the logger2 facade.
- `inventory` 0.3.10 (cached) has no wasm path; 0.3.24 adds
  `target_family = "wasm"`; stores `&'static dyn ErasedNode`. `linkme`
  0.3.37 lists no wasm; supports `#[linkme(crate = path)]`.
- infra: `githubFileAsset` only returns a `FileAsset` (needs an exported
  bytes helper); production images pinned by digest without source revision;
  bake sets `org.opencontainers.image.revision`.
- logger2 is a git dependency on `branch = "main"`, version 0.1.0.

## 1. Recording mechanism

Recommendation: `linkme` registry behind a new logger2 feature
`program-events`, registration only on non-wasm, services enable the
feature only as a dev-dependency (resolver 2/3 applies dev features only to
test/example builds), so release images carry nothing. The macro emits the
registration before the `LOG_LEVEL` branch so the file does not depend on
the build environment. `inventory` >= 0.3.24 is the fallback if a half-day
spike fails (element in a block in a fn body; element in a dependency via
`#[linkme(crate = logger2::__private::linkme)]`; element in `#[inline]` and
never-called fns).

Registry over source scanner: answers "which events does this binary
contain" incl. dependencies, and sees calls produced by `macro_rules!`
wrappers (e.g. `strats_v2`'s `state_handler!`).

```rust
#[doc(hidden)]
pub struct EventSite {
    pub event: Option<EventName>,        // None: no event name at the start
    pub level: LogLevel,
    pub format: &'static str,
    pub fields: &'static [&'static str], // keys of `key={..}` pairs
    pub alert: Option<AlertDoc>,         // only for log_alert!/log_emergency!
    pub package: &'static str,           // env!("CARGO_PKG_NAME") at the site
    pub module: &'static str,            // module_path!()
    pub in_cfg_test: bool,               // cfg!(test); dropped on export
}
pub struct EventName(&'static str);
pub struct AlertDoc {
    pub summary: &'static str,
    pub description: &'static str,
    pub notification_period_secs: Option<u32>,
}
#[cfg(all(feature = "program-events", not(target_family = "wasm")))]
#[linkme::distributed_slice]
pub static EVENT_SITES: [EventSite];
```

No `file!()` (absolute paths of git checkouts differ per machine), no line
numbers (churn). Two `__register_event_site!` macro definitions, one real,
one empty, selected by logger2's feature and target.

## 2. Event identity

Event = longest prefix matching `segment ("." segment)+`,
`segment = [a-z][a-z0-9_]*`, followed by end, space or `:`.
`"download_job.overdue dataset={}"` -> `download_job.overdue`;
`"engine.initialize.error: ..."` -> `engine.initialize.error`;
`"sim-gw.on_nats_msg"`, `"{} day={}"`, prose, `"x.y{}"` -> none.
Fields: `key=` directly before a placeholder, key `[a-z_][a-z0-9_]*`.

Strictness: `log_alert!`/`log_emergency!` must start with a literal event
name and carry a doc comment (compile error otherwise); other levels never
error, unnamed sites go to an `unnamed` list; a repo can assert stricter
rules in its golden test. Duplicate names allowed for non-alerted events
(sites listed); for alerted events the exporter fails on more than one site
or mixed levels.

## 3. The file

JSON, 2-space, trailing newline; events sorted by name; sites sorted by
(package, module, format, level); `in_cfg_test` sites dropped; no commit
hash inside.

```json
{
  "schema": "logger2.program-events",
  "version": 1,
  "program": { "package": "databento-mkt-data-download-job", "binary": "download-mkt-data" },
  "events": [
    {
      "event": "download_job.overdue",
      "alert": { "summary": "A day has a missing object.", "description": "...", "notification_period_secs": 86400 },
      "sites": [
        { "level": "alert", "package": "databento-mkt-data-download-job",
          "module": "databento_mkt_data_download_job::core::run",
          "format": "download_job.overdue dataset={} schema={} day={} hours_since_day_end={} missing_markets={}",
          "fields": ["dataset", "schema", "day", "hours_since_day_end", "missing_markets"] }
      ]
    }
  ],
  "unnamed": [
    { "level": "warning", "package": "some-shared-crate", "module": "some_shared_crate::client",
      "format": "retrying {} after {:?}", "fields": [] }
  ]
}
```

`version` bumps on rename/removal of a field only. File next to the
package's `Cargo.toml` (`program-events.<binary>.json` for several deployed
binaries). Generated by a golden test in the binary target (only that links
`main.rs`'s sites); logger2 provides `render`, `check_file`, `write_file`
and a closed `ProgramEventsError`; `UPDATE_PROGRAM_EVENTS=1` rewrites;
`just program-events` recipe; `just check` catches a stale file. "This
binary" = every site in every crate linked into the binary's test build (a
superset of reachable code).

## 4. Alerting

`log_alert!` (and `log_emergency!`) is the marker. Metadata at the call
site: a doc comment inside the macro call (summary = first paragraph) and
an optional `#[alert(notification_period_secs = ..)]`; compile errors for a
missing name/doc, `#[alert]` on lower levels, unknown keys, period < 300 s
(GCP minimum, to confirm). Rejected: a separate `describe_event!` table;
metadata in infra.

infra: `lib/program-events.ts` (zod schema v1, `readProgramEvents` on a new
`githubFileContent`, `alertedEvents`, filter builder). Text-sink filter:
`textPayload=~"^\[ALERT\] (\[[^\]]*\] )?download_job\.overdue( |:|$)"`
(anchored, so no prefix rule needed); JSON sink later:
`severity="ALERT" AND jsonPayload.message=~"^download_job\.overdue( |:|$)"`
(per-deployment `payload: "text" | "json"`). One policy per alerted event,
resource named from the event, Pulumi aliases for the two existing
policies. Revision pinned next to each digest in `docker-repository.ts`
(`{ digest, repository, revision }`), optional check against the image
label. Which deployments are watched stays in infra (scheduled job yes,
backfill no).

## 5. Migration

- logger2 (one PR, feature off by default, other repos unaffected): name
  and field extraction, attribute/doc parsing, registration before the
  `LOG_LEVEL` branch, alert-level compile errors; `program_events` module;
  text-line grammar and GCP JSON documented and pinned by tests; wasm check
  with the feature on.
- download job (replaces #9's enum): dev-dependency feature; three sites to
  `log_alert!` with literal names, docs and periods (text becomes
  `[ALERT]`, old substring filters still match); delete `alerted_events.rs`,
  the export bin, json, recipe; add the golden test and `program-events.json`.
- infra (replaces #33's table): bytes helper, `program-events.ts`, image
  source revisions, policies with legacy aliases.
- Other services opt in when needed.

## 6. Tests

Macros: table tests for name and field extraction, property tests
(extraction exact for valid names, never panics, generated keys round
trip), trybuild UI tests for the compile errors. `program_events`: table
test of validation, property test that any permutation renders the same
bytes, JSON round trip, fixture-crate integration test (dependency site,
`macro_rules!` site, `LOG_LEVEL`-filtered site; doubles as the linkme
spike). Download job: the golden test. infra: filter builder table test,
zod rejects version 2 (infra has almost no test runner yet).

## 7. Risks

Superset/cfg gaps; two logger2 copies in one graph would hide events (guard
with `cargo tree -d -i logger2`); infra filters couple to logger2's text
format (pinned by tests); event names set through context are not captured;
rustfmt skips macro calls with attributes; to verify: linkme spike,
`CARGO_BIN_NAME` in unit tests, Cloud Run severity of text lines, filter
escaping.

## 8. Decisions (agent's recommendation first)

1. Mechanism: linkme registry, `program-events` feature, dev-dependency,
   native only (fallback inventory >= 0.3.24); not a scanner.
2. Alert metadata: doc comment + `#[alert(..)]` inside `log_alert!`; or a
   `describe_event!` item; or infra.
3. Strictness: name + doc required only for alert levels; others recorded
   as unnamed, repos opt into stricter test checks.
4. `log_emergency!` alerted too: yes.
5. Filter: anchored `textPayload` regex now; `GCPLogSink` + severity later.
6. Policy names from the event name + Pulumi aliases for the two existing
   policies.
7. Duplicate names: allowed unless alerted.
8. Non-production `:latest` stages: use the production pinned revision.
9. #9/#33: merge now if the expiration alert is needed before logger2 lands
   (the migration replaces them), else close them.
