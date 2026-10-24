---
create_time: 2026-10-20T18:03:59Z
title: "Status board: production wall screen with agent panels over MCP"
summary: "Status board deployed (europe-west1, https://status-board-hhr4veseia-ew.a.run.app): Effect 4 + Bun app in monitoring ts/status-board, infra in infra main. D1 unused Mac mini kiosk; D2 Claude subscription, opencode out, Paseo; D3 one shared VM for agents (not built); D4 view-only wall + agents draw panels over MCP; D5 full Effect, no @structure, name status board; D6 production only, no DB; D7 europe-west1; D8 MCP auth = Google ID tokens, allowlist from GcpMembers (Project.StatusBoard), personal gcloud tokens OK; D9 skill + MCP; D10 shared live board, move_panel only; D11 auto reload; D12 wall token typed once -> cookie; D13 local zoom/scroll; D14 strategies summary + down only, separate services/pools/jobs, jobs running + latest 5 failed; D15 Dockerfile in infra/images; D16 own subscriptions for incidents/alerts/event logs, copied protos; D17 tables at bottom, NATS in one cell; D18 signed commits straight to main, show locally before deploy. In progress: table widths + click to expand, stats widget. Open: Paseo VM, Codex auth, lost user panels?, kiosk setup."
related_sessions:
  - SESS-00QKRBE
  - SESS-00QKS30
  - SESS-00R0FYF
  - SESS-00R0CQR
agents:
  - claude-code:b7b165ad-3ed0-4b42-a7f4-c678e68cfe56
---

# SESS-00R3X0F: Status board: production wall screen with agent panels over MCP

## Goal (2026-10-20)

The user wanted a dashboard with status pages for all services on an
always-on screen, plus an agent with read-only access to the infrastructure,
so the team can see what is going on and ask questions. The screen must not be
usable by passers-by (cleaning staff) after inactivity. Starting point: the
programmatic GCP access ideas in heimdall/README.md.

## Decisions

- **D1 Hardware.** The Mac mini is unused and empty (not a dev machine), so a
  simple dedicated account with Chrome in kiosk mode is fine. iPad Guided
  Access and third-party kiosk apps were discussed and not needed.
- **D2 Agent model access.** Claude through a subscription, not Vertex and not
  API keys. Consequence: opencode is out (Anthropic's terms allow subscription
  OAuth only in Claude Code and its own apps). Claude Code Remote Control and
  self-hosted environments were presented. The user chose Paseo (it drives
  Claude Code via the Agent SDK and Codex via `codex app-server`).
- **D3 Where agents run.** One shared VM. Asked "can it be Cloud Run?": no for
  the Paseo daemon (logins with refreshing tokens, transcripts and daemon state
  need a persistent disk); Cloud Run only for the dashboard server. Not built
  yet.
- **D4 Dashboard shape.** The user's idea: a view-only wall connected over a
  WebSocket, primitive UI blocks, and agents (through Paseo) asking the server
  to display things, with docking. Agents send panel descriptions (widget +
  source + dock + expiry), never HTML; the server runs every query with its
  own read-only credentials (Heimdall's idea in small).
- **D5 Stack.** "Full Effect.ts", Bun, no `@structure/*` packages: nobody on
  the team will support it, so whatever is easiest. Lives in the monitoring
  repo as `ts/status-board`. Name: "status board" (user preferred it over
  "dashboard").
- **D6 Scope.** Production only. No ClickHouse, no database access for now.
  No raw echarts escape hatch ("whatever is best for now").
- **D7 Region.** europe-west1: the team is in the EU. Watched workloads stay
  in asia-northeast1.
- **D8 MCP auth.** Google ID tokens. The allowlist is every member of
  `GcpMembers` in infra (user's idea: `Project.StatusBoard` in
  infra/infra/projects.ts, emails injected into the backend), stored in Secret
  Manager. Personal `gcloud auth print-identity-token` tokens are accepted
  (gcloud's client id as an extra audience), so local Claude Code can use the
  remote MCP via `headersHelper`.
- **D9 Skill as well as MCP.** The user asked for a skill with an API "if the
  MCPs are not lazy-loaded". MCP tools are lazy-loaded in Claude Code, so MCP
  stays the only interface; the skill (`ts/status-board/skill/status-board`)
  carries tested PromQL queries, log filters for the NOTICE+ sink, workload
  names and examples.
- **D10 Live updates.** Open the client once and see live updates. The board
  is shared and stateful (one instance); colleagues' panels appear for
  everyone. Rearranging: only the `move_panel` MCP tool for now (option 1); a
  browser edit mode with drag and drop (option 2) was postponed.
- **D11 Auto reload.** The wall reloads itself when a deploy changes the page
  (user: "fuck yeah").
- **D12 Wall auth.** No token in URLs (visible to everyone). The token is
  typed once into the page and kept as an HttpOnly cookie (HMAC of the token).
  HTTP basic auth and IAP were rejected.
- **D13 Client zoom and scroll.** Local to each browser, not persisted across
  clients.
- **D14 Strategies.** There will be hundreds of strategy instances: show a
  compact summary and only the ones that are down. Separate views for
  services, worker pools and jobs. Jobs: only the running ones and the latest
  5 that failed.
- **D15 Dockerfile.** Moved from the monitoring repo into
  `infra/images/status-board` like the other images (workspace-root context,
  allowlist dockerignore).
- **D16 Pub/Sub tables.** Show the latest messages of monitoring incidents,
  alerts (from the feeds topic) and event logs, without acking anyone else's
  messages. The board has its own subscriptions (acks only its copies). The
  user asked to copy the protobuf schemas instead of depending on anything
  from structure; they are unchanged copies in `src/server/feeds/proto`,
  decoded with protobufjs.
- **D17 Layout.** Tables (incidents, Pub/Sub messages) at the bottom, wide and
  not tall; strategies and services in the second column. NATS metrics
  collapsed into one cell to give CPU and memory more height (new `stats`
  widget).
- **D18 Git.** Signed commits. From 2026-10-20 evening: no PRs, straight to
  `main` in monitoring and infra. Before deploying UI changes, show the user
  how it looks locally.

## What is deployed

- Service `status-board`, europe-west1, project `stxr-prop`,
  https://status-board-hhr4veseia-ew.a.run.app (revision status-board-00003
  at the time of writing). One instance, CPU always on, public ingress; the
  app checks its own credentials.
- Base board: worker pools, jobs, services, strategies, NATS, CPU p99, memory
  p99, exits/probes/OOM, errors, incidents, latest Pub/Sub messages.
- MCP tools: `list_panels`, `preview_source`, `show_panel`, `move_panel`,
  `remove_panel`. Agent panels: at most 6, expire after 4 h by default.
- State: `gs://stxr-prop-eu-status-board/status-board/state.json`, written
  with generation preconditions; the newest instance claims it at start.
- Subscriptions: `status-board-monitoring-incidents-sub`,
  `status-board-alerts-feed-sub` (same filter as notify-gw's alerts sub),
  `status-board-event-log-sub` (1 h retention).
- Commits: monitoring c1c3de4 on main (after PRs #4, #5, #6); infra fce4e57 on
  main (after #51, #53). Image pinned to the build of c1c3de4.

## Findings along the way

- databento-mkt-data-server exited with code 1 ~30 times between 15:33 and
  17:15 local on 2026-10-20 while Cloud Run reported it ready. This led to
  the Cloud Run source counting exits/probe failures/OOM (warn at 1, fail at 3
  in 15 min).
- application-server answers ~1.2 req/s 4xx vs ~0.1 req/s 2xx (2026-10-20
  evening). Not investigated; see SESS-00R0CQR.
- Cloud Run reserves `PORT` as an env var (first `pulumi up` failed) and URL
  paths ending in `z` (`/healthz` is unreachable from outside; probes work).
- Exiting with code 1 when superseded opened a `service-exited` incident on
  every deploy. Now the outdated instance retires (stops saving, pulling and
  serving walls) and waits for Cloud Run's graceful stop; it exits after 2 min
  only if nobody stops it. Tested with two local instances on a test object.
- During a deploy the old instance kept serving existing WebSockets during
  graceful shutdown; wall streams now end on SIGTERM and every 10 minutes.
- The project's log sink drops Cloud Run lines below NOTICE, so INFO logs and
  successful request logs of the board are not stored.

## In progress (not committed)

- Table columns sized by content, the message column takes the rest; click a
  row of a table or log list to expand it (local only).
- `stats` widget and the single NATS cell (server side done, page side with
  the web agent).
- Proposed by the agent, not confirmed by the user: timeseries legends rank
  series by peak over the window instead of the latest value, so a past spike
  stays named.

## Open

- Paseo VM (GCE, read-only SA, egress proxy, `MCP_SERVICE_ACCOUNT_EMAILS`
  hook in infra).
- Codex MCP auth: it only sends a static bearer token, and ID tokens expire
  hourly.
- The user asked to remove "the ones I created over MCP": only two agent
  panels existed, created by the agent with `by: cheerful-capuchin` (mistake:
  they looked like the user's); both removed. If the user created others,
  they may have reached the old instance during the deploy and been lost.
  Possible fix: a retired instance refuses MCP changes with a retry error.
- Mac mini kiosk account setup.
