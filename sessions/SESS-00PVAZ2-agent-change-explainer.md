---
create_time: 2026-10-05T08:50:42Z
title: "Agent change explainer"
summary: "Change viewer: Tauri, Rust core, TS UI, comments as event log; agent explainer on top; session = SESS file only; paseo agent spawns a dev environment via heimdall (not built yet); no Clef, no video"
related_sessions:
  - SESS-00PE96K
---

# SESS-00PVAZ2: Agent change explainer

## Context (2026-10-05)

A workflow ran for about two days on the strategy deployments work
(SESS-00PE96K, DEC-0BZBC, PLAN-0BZET, PLAN-0BZEW, PLAN-0BZEY) and wrote
thousands of lines across the submodules. The user does not want to review
every line. The user wants a tool that explains what the agents changed, based
on Karpathy's post about understanding LLM output (ASD-STE100 writing,
diagrams, HTML pages, explainer videos).

Facts measured on 2026-10-05 for the first input:

- Commits since 2026-09-30 across 17 submodules: about +80k / -34k lines.
- Workflow commits carry a `[PLAN-<id> T<n>]` prefix in the subject, so the
  workflow's commits can be selected by tag instead of by date. Many are
  "review fixes" commits.
- Most of the event-gw diff (+14k / -14k) is one insta snapshot,
  `host_snapshot_tests__host_egress.snap` (about 27.7k changed lines).
- SESS-00PE96K holds decisions D1 to D25 and findings F1 to F3; they are the
  intended behaviour the code can be checked against.

## Decisions

### D1. No Clef classifier for now (2026-10-05)

Do not integrate Cloudflare's Clef decision model
(https://blog.cloudflare.com/clef-decision-models/) to decide what the
explainer shows. "Yet": the user may revisit it later.

Reasoning accepted by the user: one report per workflow run is far too low a
volume for a dedicated classifier; path rules (snapshots, lockfiles,
generated code), git move detection and LLM subagents with structured output
cover the triage; Clef would add a model to host.

### D2. No explainer video (2026-10-05)

No narrated or animated video output. Out of scope.

### D3. Output is HTML (2026-10-05)

The explainer output is an HTML page. The user said "HTML is fine unless
there is something more useful", so a better format can still be proposed,
but HTML is the default.

### D4. A separate application in its own git repository, plus a skill (2026-10-05)

- The explainer is a separate application with its own git repository. The
  user placed it in "~/workspace/". `~/workspace` does not exist on this
  machine; the likely meaning is the stxr workspace root
  (`/Users/doichevkostia/work/stxr/workspace`). Confirm the path and the
  repository name before creating it.
- A skill is required as well (the agent entry point that drives the app).

### D5. Scope widened: a diff viewer first, the explainer on top (2026-10-05)

The user wants two levels over one abstraction for "viewing changes":

1. **Diff view (detailed).** A separate diff application, backed by git or
   jj, where the user scrolls through diffs. Sources: unstaged and staged
   changes, commit to commit, branch to branch. Motivation: the user uses the
   RustRover git integration a lot and sometimes opens RustRover only to look
   at a diff.
2. **Explanation (abstract).** The session progress and the changes the
   agents made. It must render diagrams, code, markdown, tables and SQLite
   queries.

Rendering candidates named by the user: `@pierre/diffs` (diffs.com) and
`@pierre/trees` (trees.software).

### D6. Review comments on highlighted changes, stored as data (2026-10-05)

- The user highlights changes and comments on them in the diff view.
- Comments live in a data file, "prolly" SQLite or another format, probably
  as an event log so comments can be rolled back. Format not final.

### D7. RustRover and GitHub only to open a file (2026-10-05)

Opening a file is an explicit action that goes to RustRover or GitHub. The
diff viewing itself moves out of RustRover into the new app. This answers the
earlier RustRover integration question: no plugin, only "open in" links.

### D8. Local native app: Tauri, Rust core, TypeScript UI only (2026-10-05)

The app is a local native desktop app ("tauri?", Tauri is the working
choice). All core logic is Rust; TypeScript is used only for the UI. Replaces
the "local web app" shape proposed earlier the same day.

### D9. Agent work runs outside the laptop; session info stays on the laptop (2026-10-05)

- Brainstorm session records stay on the user's laptop.
- When it is time to execute, the work environment is created outside the
  user's machine, so the user is not blocked and does not spend time on local
  git worktrees. The user does not want "a bunch of git worktrees all over
  the place".
- Platform not chosen. The user named Cloud Run worker pools and celld as
  candidates (see findings).

### D10. Keep user decisions apart from agent sessions and their context (2026-10-05)

The user wants a clear split between (a) the context and decisions made in
the user's design sessions (the brainstorm records) and (b) agent execution
sessions and their own context. How to model the split is open.

### D11. "Session" means the user's SESS file only (2026-10-05)

"By session I mean the sess file that I keep." Agent conversations are not
sessions. Refines D10: the split is between SESS files (user context and
decisions) and agent work (paseo agents and their transcripts).

### D12. Target flow: paseo agent spawns a dev environment through the platform API (2026-10-05)

- paseo (paseo.sh) is the user's harness orchestrator.
- Desired flow: the user tells an agent (in paseo) to use the Structure dev
  platform API, `heimdall`, to spawn a "dev environment" outside the laptop.
  Agents work there until the feature is ready; then the user reviews.
- This is the user's preferred direction over Claude Code cloud sessions,
  which were only proposed (D9 left the platform open).

### D13. Repository: stxr-prop/dev-env (2026-10-05)

Private GitHub repo `stxr-prop/dev-env`, created 2026-10-05. Resolves the
location question in D4. The app is called "dev-env".

Moved the same day to `/Users/doichevkostia/work/stxr/dev-env`, with a symlink
`workspace/dev-env -> ../dev-env`: the workspace root `.cargo/config.toml`
`[patch.crates-io]` (vendored serde_json etc.) applied to the nested checkout
and broke dependency resolution. Cargo resolves the symlink to the real path,
so the parent patches no longer apply.

Moved again on 2026-10-06 to `~/personal/dev-env`; the workspace symlink was
removed.

### D14. Local v1 only: diff viewer, notebooks, annotations (2026-10-05)

v1 is local. No dev environment spawning and no cloud orchestration (D9, D12
are parked).

### D15. Change view modelled on the IntelliJ commit tab (2026-10-05)

- Covers every git submodule of the project. git only, no jj for now.
- Sources: unstaged changes (collapsed by default), staged changes in a tree
  view, commit to commit, branch to branch.

### D16. Sessions are created by hand; no commit selection (2026-10-05)

- A "create session" action attaches a SESS file. The app does not select
  commits by PLAN tag or by date.
- For now all git history relates to all sessions.

### D17. Notebook blocks and a UI capability (2026-10-05)

- A notebook shows diagrams, text, tables and code snippets. Snippets run
  through the platform API when the user clicks run.
- The program renders its results through `platform.ui()`:
  `platform.ui().section` is the id of the block the output goes to;
  primitives are text, blocks, tables (table, row, column) and lists.
- The file format is the implementer's choice.

### D18. Projects and per-session data (2026-10-05)

- The user opens a directory as a project, as in IntelliJ.
- Each session has its own directory,
  `<project>/.dev-env/data/sessions/{session_id}`.
  `platform.fs().current_dir()` returns it.
- A session can hold several notebooks but has one SQLite file with the
  annotation event log and the computed view.

### D19. Runtime copied from heimdall, not shared (2026-10-05)

- heimdall style: generator programs that `yield*` effects, run in QuickJS
  inside the Rust host.
- Copy what is needed from heimdall; no shared packages. heimdall is a
  reference only.
- Types are stripped in Rust at run time; typechecking happens in the editor
  against the API's `.d.ts`.

### D20. Capabilities: fs, sqlite, http, gcp, secrets, ui (2026-10-05)

- HTTP may call any host.
- GCP auth is a separate `platform.gcp().auth()`.

### D21. Secrets from env vars behind Touch ID (2026-10-05)

- The real adapter reads environment variables, with lowercased names.
- Access is guarded by Touch ID or the passcode, once per run, with a
  session-wide "always allow" option.
- A mock secret store without Touch ID exists for the agent's development
  loop. The CLI uses only the mock store; the GUI uses only the real store.
- Programs receive the raw secret value. Placeholders substituted by the host
  were rejected as too much work (2026-10-05).
- Lookup is by lowercased name: `get("github_token")` finds `GITHUB_TOKEN`
  (confirmed 2026-10-05).
- Env vars come from the project's `.envrc`, loaded through direnv (user
  uses direnv; confirmed 2026-10-05).
- `platform.gcp().auth()` returns a token from gcloud's default credentials,
  behind the same Touch ID gate (confirmed 2026-10-05).

### D26. Runtime placement, session ids, socket failure (2026-10-05)

- QuickJS runs inside the Rust core. The UI sends the TS source to Rust,
  which strips types and executes it. The webview never runs program code.
- The session id is the attached SESS file's id, lowercased; the session
  folder is `.dev-env/data/sessions/sess-<id>`.
- If the app is not running, the CLI's socket request fails ("open
  dev-env"); it does not launch the app.
- QuickJS is embedded natively through `rquickjs`, with a memory limit and
  a timeout; no WASM cage for now (2026-10-05).

### D22. Annotations and agent access (2026-10-05)

- The user can annotate diff lines, notebook sections and cell outputs.
- Anchor: path, commit, line range, selected text with surrounding context,
  a text hash and the enclosing tree-sitter symbol path. Re-anchoring tries
  an exact match, then a fuzzy match, then the symbol.
- Events: added, edited, resolved, reopened, deleted. Agents can reply in a
  thread.
- Agents reach the running app over a local socket (or similar). Every request
  carries the session id.

### D23. Open in RustRover and GitHub (2026-10-05)

- RustRover opens files against the workspace root.
- The GitHub action is disabled for unpushed commits and uncommitted changes.

### D24. UI stack (2026-10-05)

shadcn, `@pierre/diffs`, `@pierre/trees`. Not `@structure/ui`: dev-env is an
unrelated developer product. No charts for now.

### D25. Skill location (2026-10-05)

The skill lives in `~/.agents/skills`, symlinked into the workspace
`.agents/skills` and wherever each agent provider expects skills.

### D27. Session event log uses the personal finance book format (2026-10-05)

Annotation events (and the rest of the session log) are encoded like
`~/personal/finance` (`crates/core/src/event/`, `log.rs`, `db/schema.sql`):
Avro binary payloads, writer schema stored by its Rabin fingerprint, BLAKE3
hash chain, append-only triggers, pinned revisions test, BLAKE3-derived ids,
a plain text info table. Written into dev-env plans 01, 03, 04 as REQ-05 and
REQ-25.

### D28. Plan review answers (2026-10-05)

- The `Platform` type only contains capabilities the host provides; a
  failed capability call throws ("panic is acceptable").
- swc StripOnly for type stripping; narrow capabilities (session-confined
  read-only fs, read-only sqlite, read-only cells); separate real and mock
  secret crates; socket at `~/.dev-env/run/dev-env.sock`; `tsc` for
  `dev-env check`.
- No secret masking for now.
- Touch ID always guards the real secret store, in dev and release builds.
- No ralphex; plans run with native agents and workflows. The workspace
  `agent-plan` skill was deleted.
- dev-env is its own workspace; it does not refer to parent directories.

## Findings (2026-10-05)

- `@pierre/diffs` 1.5.1 (Apache-2.0, npm): Shiki-based diff and code
  renderer, web components in shadow DOM, split and unified layouts, line
  selection, annotation framework for comments, accept/reject buttons, merge
  conflict UI. Depends on `diff`, `shiki`.
- `@pierre/trees` 1.0.0-beta.6 (Apache-2.0, npm): path-first file tree,
  `gitStatus` decorations, `flattenEmptyDirectories`, keyboard navigation,
  Preact/vanilla core with React wrappers.
- celld (denoland/celld, v0.6 beta) is a self-hosted Cloudflare Durable
  Objects / Workers runtime (embedded V8, SQLite per "cell", replicated to an
  object store). It is not an agent sandbox and has no working-copy or git
  isolation. It does not by itself give "many agents running concurrently".
- jj does not support git submodules. The stxr workspace is a submodule tree,
  so a jj backend works per submodule repo, not on the workspace root.
- celld cannot host agent sessions: Workers run in V8 isolates with no
  processes, shell, git or cargo.
- Claude Code cloud sessions (docs fetched 2026-10-05): run in an
  Anthropic-hosted VM or in a "self-hosted environment". Self-hosted is a
  public beta for Team and Enterprise plans, off by default, enabled by an
  org Owner. A long-lived runner process on your hosts polls
  `api.anthropic.com` (outbound only), clones from GitHub, spawns one Claude
  Code child per session up to `--capacity`; with `--drain-grace-sec 0` it
  exits after its sessions so the host restarts it with a fresh disk.
  Kubernetes and Compose recipes exist. This pull model fits a Cloud Run
  worker pool or a GCE VM.
- Cloud session control from the laptop: `claude --cloud "<task>"` starts a
  session (one repository per `--cloud` call; the web UI accepts several
  repositories), `claude -p "<msg>" --cloud <session-id>` queues a follow-up
  message, `claude --teleport <id>` pulls a session and its branch locally.
  The cloud clones the pushed GitHub state, not the local checkout.
- Cloud Run jobs: task timeout up to 168 hours. Cloud Run worker pools: only
  ephemeral disk, in-memory or NFS volumes; no persistent local disk.
- Workspace facts: remote `cheerful-capuchin/stxr-mono`, 70 submodules,
  45 modified submodule pointers uncommitted and the current branch not
  pushed on 2026-10-05; root `target/` is 126 GB, so cold Rust builds in a
  fresh environment are expensive without a shared build cache.
- brainstorm has a private remote, `cheerful-capuchin/brainstorm`.
- heimdall (stxr-prop/heimdall, workspace dir `heimdall/`) today: a
  prototype of capability-secured TypeScript execution (QuickJS in WASM,
  programs yield effects, host checks permission and holds credentials,
  SSE response, target Cloud Run). The `gcp()` capability is commented out in
  `packages/platform/src/platform.ts`, the Rust host `src/main.rs` is 3
  lines, the todo says "No GCP capabilities yet". No dev environment
  capability exists. Matching invariant: "The program names logical
  resources; the host resolves them."
- paseo: local daemon (`~/.paseo/config.json`, `daemon.listen`
  127.0.0.1:6767, relay enabled). The daemon owns agent lifecycle,
  worktrees and dev servers. Clients reach remote daemons over SSH
  (`paseo --host ssh://user@host`), the end-to-end encrypted relay
  (`paseo daemon pair`) or Tailscale; the desktop app holds several hosts
  ("Settings → Add host"). `paseo run --background`, `paseo run
  --new-workspace worktree --base <ref> "<prompt>"`, `paseo workspace
  create`, `paseo ls -a`. `paseo.json` keys: `worktree.setup`,
  `worktree.teardown`, `worktree.terminals`, `worktree.servicePorts`,
  `scripts`. Workspace root `paseo.json` is `{}`. Daemon installs with
  `npm install -g @getpaseo/cli` or Docker.

## Open: concurrent agents (2026-10-05)

The user floated running many agents concurrently (celld named) and only
reviewing their changes. Not decided; see the celld finding above.

## Open: linking a session to a change list (2026-10-05)

The user may want to link a brainstorm session to the files and change list
under review. "idk yet".

## Proposals not yet decided

Put to the user on 2026-10-05; the user accepted only the HTML format (D3):

- Anchor the explanation on the intent records (session decisions, DEC,
  PLAN) instead of the raw diff: a coverage table per decision with status
  (implemented / partial / missing / contradicted) and evidence links to
  commit and `file:line`.
- Page sections: one-screen summary in roughly 80% ASD-STE100; decision
  coverage; before/after diagrams (entities, call flow, state machine);
  change map by repo and kind (logic, generated, snapshot, lockfile, move,
  test); a short "read this yourself" list; an end-to-end request
  walkthrough; loose ends.
- Pipeline: deterministic collect script, intent extraction, per-plan or
  per-repo subagents with JSON output, an adversarial verify pass, then a
  fixed HTML template rendering the JSON plus model-written diagram source.
- Select commits by PLAN tag rather than by date.

## Open questions

- The app repository must not reference the `brainstorm` directory (workspace
  rule); session files have to be passed in as inputs.
