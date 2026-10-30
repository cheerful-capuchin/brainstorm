---
create_time: 2026-10-28T18:03:44Z
title: "Status board activity feed: org and vendor news"
summary: "Activity feed + shared canvas released 2026-10-28 (monitoring e09bb8d). D6 replaces D5: stxr-prop GitHub activity via a github feed kind, D7 reuses the daily-brief PAT for now; canvas decisions C1-C10"
related_sessions:
  - SESS-00R3X0F
agents:
  - claude-code:5dade95a-30a0-42a3-9216-a581bf30a57f
  - claude-code:854b3564-d498-4f36-9a1f-bb58cfd46986
---

# SESS-00RS000: Status board activity feed: org and vendor news

## Request (2026-10-28)

User wants an activity feed on the status board ("twitter/reddit but only what matters to us"):
every push to main on GitHub, GCP releases and news, Anthropic, OpenAI, Cloudflare, Hyperliquid news, and similar vendors.
Asked how we would do it. No decisions made yet.

## Feed availability checked 2026-10-28 (curl)

- Exist: GCP release notes `cloud.google.com/feeds/gcp-release-notes.xml` (all products, needs filtering), GCP status `status.cloud.google.com/en/feed.atom`, Google Cloud blog `cloudblog.withgoogle.com/rss/`, OpenAI news `openai.com/news/rss.xml`, OpenAI status, Claude status `status.claude.com/history.rss`, Cloudflare blog `blog.cloudflare.com/rss/`, Cloudflare changelog `developers.cloudflare.com/changelog/rss.xml`, Cloudflare status, GitHub `releases.atom` per repo (e.g. anthropics/claude-code).
- Missing: Anthropic news has no RSS (anthropic.com/news would need scraping). Hyperliquid Medium feed is dead (last post 2024-01); their announcements are on X, Discord, Telegram.
- Databento status RSS URL guessed wrong, not found.

## Proposal given (not accepted yet)

- Phase 1: new `activity` source in status-board, pull-only, stateless: panel spec lists feeds (rss/atom, statuspage, github org); server fetches on its refresh interval, filters by per-feed include rules, merges newest first. Upstream feeds are the history, so nothing new stored. New `activity` widget (source icon, title, age, new items lit like deploys).
- GitHub pushes to main: poll GraphQL default-branch history for all org repos (one query per refresh) with a GitHub App / token in Secret Manager. Rejected in proposal: REST org events API (GitHub documents 30 s to 6 h latency).
- Phase 2 (only if wanted): relevance filter with Haiku, GitHub webhook, Discord/agent consumers -> separate ingester publishing one normalized ActivityItem feed to Pub/Sub; status-board reads it via the existing `pubsub` source (tail saved with board state).

## Open questions put to the user

1. Wall only, or also Discord / agents?
2. Filtering by rules, or LLM relevance?
3. Hyperliquid source: Telegram public channel, Discord follow into our server, or paid X API?
4. GitHub scope: which orgs, all repos; also vendor repo releases (effect, bun, pulumi)?

## Decisions (2026-10-28)

- D1: Readers: the wall only. No Discord or agent consumers, so no separate ingester / Pub/Sub topic (phase 2 consumers dropped).
- D2: No filtering for now. Add filtering only if the feed floods. (Answers open question 2; neither rules nor LLM yet.)
- D3: Feeds are added dynamically by agents over MCP/API. Nothing hardcoded: no built-in vendor list in code. (Answers open question 4.)
- D4: Each item shows a summary and can be expanded to see more details.
- D5: Skip our own GitHub (pushes to main) for now; public sources only. The GitHub GraphQL / token part of the proposal is dropped for now.

## Telegram (open question 3, follow-up)

User asked whether Telegram can be read programmatically for free. Checked 2026-10-28:
- `https://t.me/s/<channel>` public web preview: free, no account, HTML with message ids and `<time datetime>`. `hyperliquid_announcements` ("Hyperliquid Announcements", 26.7K subscribers, post 600 on 2026-10-28) looks like the official one; not confirmed from Hyperliquid docs.
- Bot API cannot read channels the bot is not admin of.
- MTProto client API (api_id from my.telegram.org, gramjs/TDLib) is free but needs a phone-number user account and a stored session.
Recommendation given: t.me/s scraping as a `telegram` feed kind. Not decided.

## Plan written (2026-10-28)

User asked for the design as a plan. Written to `monitoring/ts/status-board/docs/plans/2026-10-28-activity-feed.md` (uncommitted; no brainstorm references in it, decisions restated inline).
Proposed in the plan, not separately confirmed by the user: `activity` source with `rss` and `telegram` feed kinds (Telegram via t.me/s scraping), `fast-xml-parser` dependency, HTMLRewriter HTML-to-markdown converter, details fetched lazily over a new `ActivityDetail` wall RPC (not in the frame), `activity` widget with `item_open` panel state, SSRF guard on agent-given URLs, default refresh 600 s, 14 days, 50 items. Anthropic news (no feed) out of scope.

## Implemented (2026-10-28, uncommitted)

User said "implement it now". Done in `monitoring/ts/status-board` (not committed, not deployed); `just check` passes.
Deviations from the plan, recorded in the plan file: `htmlparser2` instead of `fast-xml-parser` + HTMLRewriter (tests run under Node, which has no HTMLRewriter); `ActivityDetail` RPC takes `{ messageId }` only, details kept in one bounded in-memory map (1,000 items) rather than per panel; body cap 20 MB (Cloudflare changelog is 8.3 MB); posts deduped per feed by id or by title+time (OpenAI publishes some posts under two URLs).
Verified live against the real feeds with a local server, MCP (create_view `news`, show_panel, preview_source refusing 169.254.169.254, send_panel_event open_item/back) and headless Chrome screenshots.

## Shared canvas (2026-10-28, requested)

User asked whether the status board has an interactive canvas synced within an instance (it does not; only view + panel states are shared via ChangeInstance + snapshots). User then asked for a design of an interactive drawing canvas shared across all clients of the same wall instance; delegated to an Opus subagent, output to be `monitoring/ts/status-board/docs/plans/2026-10-28-shared-canvas.md`. Design only, no implementation yet.
Also 2026-10-28: user declined ("not now") the activity feed memory-budget fix (convert entries at parse time, per-store byte budgets, 10 MB body cap, 4 concurrent reads). Open.
Design written by the subagent (proposal, not accepted): `canvas` panel kind (not overlay), one drawing per instance+view+panel outside instance state, fixed 3200x1800 integer surface as SVG, separate `WatchCanvas`/`Draw` RPCs with full-snapshot catch-up, idempotent actions folded by one pure function, Draw button to arm input, saved in the board JSON with caps (20k points/canvas, 100k total), MCP get_canvas/draw_on_canvas/erase_on_canvas. 8 open questions listed in the plan file; none answered yet.

### Canvas decisions (2026-10-28)

- C1: A `canvas` panel, not an overlay over the whole board, "for now". User had not considered the overlay; may revisit later.
- C2: Pages without an instance name draw locally and lose the drawing on reload: fine.
- C3: A drawing stays until someone clears it (no fade or expiry).
- C4: A full canvas refuses new strokes (does not drop the oldest).
- C5: Agents can do everything (read, draw, erase); ideally they can also request a screenshot (image) of the canvas back.
- C6: Freehand strokes in six colors and three widths, fixed 16:9 surface: accepted for the first version.
- C7: The canvas is locked by default; a person unlocks it to draw. Whether the lock is per page or shared by the instance, and whether it relocks by itself, was asked back (open).
- Open: scope of a drawing, per instance per panel (subagent's plan) vs one per panel across instances; asked back to the user.
- C8: Drawing scope: per instance per panel (every page of one instance shares it; other instances have their own). Settles the open scope question.
- C9: Unlocking to draw is per page (unlocking a laptop does not unlock the office TV). Idle relock not answered.
- Screenshot for agents: user asked whether the page (client) could export the PNG instead of the server rendering it; trade-off explained, choice open.
- C10: Agent screenshot of the canvas is rendered on the server (strokes -> SVG -> PNG via @resvg/resvg-js), not requested from a page. Reason: works with no page open; page export would need server-to-page requests, timeouts and picking a page.
- Implementation of the canvas delegated to the same Opus subagent that wrote the design (2026-10-28). Idle relock still open; implemented as: locked on every load, unlocked until the person locks it or reloads.

### Canvas implemented (2026-10-28, uncommitted)

Built by the Opus subagent in monitoring/ts/status-board; just check passes (528 tests). WatchCanvas/Draw RPCs, shared pure fold in src/shared/canvas.ts, MCP get_canvas/draw_on_canvas/erase_on_canvas/screenshot_canvas (PNG via @resvg/resvg-js), state saved with the board. Agent strokes are straight lines (hand strokes smoothed). Verified live with two headless pages per instance. Unverified: real pen/palm, simultaneous drawers, 4K, full cap, deploy switchover, resvg in the Linux image. One unexplained slow Clear (>800 ms) seen once. Open: idle relock, overlay.

### Released (2026-10-28)

monitoring e09bb8d (signed, pushed to main): activity feed + shared canvas, README and skill updated. Image asia-docker.pkg.dev/stxr-prop/images/status-board@sha256:544dd51c… (resvg + htmlparser2 load checked in the image). infra ad65ee6 (signed, pushed to main) pins it. Awaiting `pulumi up` by the user.

### Production panel (2026-10-28)

Production runs the new image (revision status-board-00019, user ran pulumi up). User asked for the activity feed in the `markets` view, splitting the Bloomberg youtube panel. Panel `vendor-news` docked right of `bloomberg` (50/50). Feeds: GCP release notes, GCP status, Google Cloud blog, Claude status, Claude Code releases, OpenAI news, OpenAI status, Cloudflare blog, Cloudflare changelog, Hyperliquid Telegram, and from GitHub (user's choice) rust-lang/rust and tokio-rs/tokio releases. Left out by the agent: Cloudflare status (datacenter maintenance notices dated on the future maintenance day sit on top for days). Noted: GitHub releases.atom only has `updated`, so editing old Rust releases bumps them to the top.

## Our GitHub org in the feed (2026-10-28)

User asked what it takes to get stxr-prop activity into the activity feed. 149 of 153 stxr-prop repos are private, so the anonymous `rss` kind cannot read them; a new `github` feed kind with a server-held credential is needed. Agent recommended a dedicated read-only GitHub App.
- D6: Replaces D5: our own GitHub org is shown after all.
- D7: Credential for now: reuse the PAT the daily brief uses (stxr-dev-automation/automations/daily-brief, Secret Manager `daily-brief-gh-token` in stxr-prop-dev; user confirmed it is a PAT), copied into the infra stack as a status-board secret. The read-only GitHub App is not done "for now". The license App (STXR_LICENSE_APP_*) was not proposed for it: it has write access.
- User asked to build the feed kind together with the infra wiring. Not answered (agent picks defaults): commits on the default branch vs merged PRs, own panel vs inside `vendor-news`, filtering of noisy commits.

### github feed kind built (2026-10-28)

- monitoring/ts/status-board (uncommitted): `github` feed kind `{ name, org }`; `GithubCommits` in src/server/sources/activity/github-commits.ts reads GraphQL: list the 50 most recently pushed repos each read, re-read commits (20 per repo, 5 repos per request, 4 at a time) only for repos whose pushedAt changed. Live: first read 5.7 s, next 0.8 s. Merge commit titled with the PR title; wrapped message lines rejoined. Token from optional `GITHUB_TOKEN`; just check passes (534 tests).
- Defaults the agent picked, not confirmed: every commit on the default branch (merged branch commits show next to the PR merge commit), committer date as time, title `<repo>: <subject>`.
- PAT facts: classic `ghp_`, owner cheerful-capuchin, scope `repo` (read and write), no expiry header.
- infra a47bd37 (signed, committed, NOT pushed, per the user): `status_board:github_token` in Pulumi.production.yaml, Secret Manager `status-board-github-token`, GITHUB_TOKEN env. Preview: 3 creates + service update. User: "commit infra, don't push. I'll deploy and see how it works when I push". The pinned image does not have the feed kind yet.
- monitoring 7e1c00a (signed) pushed to main 2026-10-28 at the user's request; image not built, infra pin not moved yet.
- Released 2026-10-28: image @sha256:6e9ff89e… pinned in infra 2c015fc; `pulumi up` by the agent at the user's request (revision status-board-00021); infra a47bd37 + 2c015fc pushed after the user checked the wall.
- D8: the stxr-prop `github` feed goes inside the existing `vendor-news` panel (markets view), not its own panel ("no, not a separate pane"). The separate `stxr-prop-commits` panel the agent added was removed.
- Panel `vendor-news` retitled "Activity" (user asked for "activity" or "news feed"); id unchanged.
