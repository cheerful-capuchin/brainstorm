---
create_time: 2026-10-15T10:57:01Z
title: "structure-web changes pulled on 2026-10-15"
summary: "Explainer notebook structure-web-pull-2026-10-15 for the 2026-10-15 structure-web pull (6cdf4e863..d927b6fde, PRs #178-#182): StrategyRevisions service split, StrategyRevision* renames and looser text fields, typed logging policy (no source events), pin K publish test, fmt. No user decisions."
related_sessions: []
agents:
  - claude-code:8dbb9c12-a663-4aae-9a00-275516aa295b
---

# SESS-00QNY3X: structure-web changes pulled on 2026-10-15

Explainer notebook `structure-web-pull-2026-10-15` in dev-env session `sess-00qny3x`, with
`pulled-prs.json` built from git over `6cdf4e863..d927b6fde`.

Points the notebook raises for the user:

- #178 moved the five revision methods from `Strategies` to a new `StrategyRevisions` service;
  old calls get "Unknown method".
- #178's "Lint + Fmt" commit also removed the API server's `AlertSink` and `EventSink`. The user's
  structure-web#183 (`alerts-through-feed`) is already rebased on `d927b6fde` and puts the alert
  sink back on the feeds topic.
- #180 replaces the logging policy `bytes` with a typed message; source events dropped from the
  protocol, storage always writes `SelectNone`.
- #181 (PLAN-0CHW2 Task 5) adds tests only; no `@structure/dsl-compiler` bump because the git dep
  has no commit and structure-web has no lockfile.

No user decisions yet.
