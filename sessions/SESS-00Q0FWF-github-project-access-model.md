---
create_time: 2026-10-07T07:45:19Z
title: "GitHub access by project with resolved repo dependencies"
summary: "github.ts access: projects -> members+role, deps resolved from manifests; restricted repos engine, ingress-egress, multihost-generator, runtime need PR, bypass capuchin+gorilla via team; no auto pulumi up; D7 mini RBAC <group>.<level>, domain groups (trade, marketdata, solana, drift, jupiter, wiki, iam, strategies, workflows, hyperliquid, data-feed), default viewer"
related_sessions: []
---

# SESS-00Q0FWF: GitHub access by project with resolved repo dependencies

## Context

GitHub teams, team memberships, team repository access and branch rulesets
for the `stxr-prop` org are managed by Pulumi in `infra/infra/github.ts`.
Today every project has a hand-written list of repositories (`ProjectRepos`,
`ENGINE_BASE`), a hand-written registry of all repos (`Repo`), a hand-written
list of shared libraries that contributors may only read (`MEMBER_ONLY_REPOS`),
and one hand-written function per team.

Problem stated by the user: when a repo starts depending on another internal
repo (Cargo git dependency, package.json git dependency, submodule), the
members of every project that uses it lose the ability to build until the
new repo is added to the project's list by hand. The user has to keep doing
this manually.

## Requirements set by the user

- R1. The user thinks in projects and teams, not in individual repositories.
  The configuration must be expressed that way.
- R2. A very compact list at the top of `github.ts` states which members
  belong to which project and with which permission scope. Example given:
  "members a, b, c belong to project backtest".
- R3. Assigning a member and their permission scope is the only manual step.
  Everything else (which repos, dependency repos, teams, team repository
  permissions) is resolved internally.
- R4. Internal repo dependencies must be resolved automatically, so a new
  internal dependency does not require a manual edit.

## Proposal (not yet accepted by the user)

- Each project declares only the repos it owns plus members per role
  (read / write / maintain). Teams `{project}-{readers|contributors|maintainers}`
  are generated from it.
- Dependency closure computed at Pulumi run time: read manifests
  (`Cargo.toml`, `.cargo/config.toml`, `package.json`, `deno.json`,
  `.gitmodules`) from each repo's default branch over the GitHub API, extract
  `stxr-prop/<repo>` references, walk transitively from the owned repos.
- Owned repos get the role's permission; dependency repos get `pull`. This
  replaces `MEMBER_ONLY_REPOS`, `ENGINE_BASE`, `ProjectRepos` and the `Repo`
  registry. Branch rulesets apply to every non-archived org repo.
- Safeguard: a restricted set of repos that resolution refuses to grant
  through a dependency edge; preview prints the dependency path for each
  granted repo.
- Migration needs Pulumi `aliases` for renamed TeamRepository / TeamMembership
  resources, because a create-then-delete of the same team+repo pair removes
  the access.

## Decisions (2026-10-07, answers to the proposal)

- D1. Permission on a repo depends on the repo, not on whether the project
  owns it or reaches it as a dependency. Repos split into two sets:
  restricted repos require a pull request to change the default branch;
  non-restricted repos can be pushed to main straight away.
  Agent reading: the owned/dependency split from the proposal is dropped;
  members get their role's permission on every repo in the project's
  resolved set, and branch rulesets decide whether main needs a PR. This
  widens access compared to `MEMBER_ONLY_REPOS` (contributors had `pull`
  on shared libraries). Flag it to the user if it turns out otherwise.
- D2. Restricted repos: `engine`, `ingress-egress`, `multihost-generator`,
  `runtime`. On them only `cheerful-capuchin` and `grumpy-gorilla` may push
  straight to main; everyone else goes through a pull request. Replaces the
  old rule where every repo required a PR and the Maintain repository role
  could bypass it.
- D3. No scheduled or automatic `pulumi up`. The user runs `pulumi up`
  often, the team is three developers, and new projects are added
  knowingly. `github.ts` stays in the main Pulumi program.
- The proposal's other "restricted" idea (refuse to grant a repo reached
  through a dependency edge) was not taken up; the user's restricted list
  is about the pull request requirement.

## Decisions (2026-10-07, round 3)

- D4. The bypass team for the restricted repos is `engine-maintainers`
  (cheerful-capuchin, grumpy-gorilla).
- D5. The repo listing and manifest reads use bulk GraphQL requests.
- D6. The resolved dependency list is tracked ("kept staged") in the infra
  repo so changes show up in review.
- D7. Access is a mini RBAC, like GCP IAM: roles `<group>.<level>` (example
  given: `strategies.maintain` covers all strategy repos) are assigned to
  members. Replaces the D1 reading that members get their project level on
  every reachable repo.
- D8. Repos are grouped by domain. Groups named by the user:
  trade (numerics, trade, common, accounting), marketdata (marketdata,
  marketdata-core, market-info-core, market-info), solana (all solana repos),
  drift, jupiter (jup-research), wiki, iam, strategies, workflows,
  hyperliquid (bridge and all hyperliquid repos), data-feed (data-feed-core).
  The default role on every group is viewer; some people or projects need
  more, granted by explicit bindings.

## Cost of resolution at `pulumi up`

- The user does not want `pulumi up` to fetch many files from GitHub on
  every run. They asked for a maintained list of all dependencies, kept up
  to date by listening to pushes in all repos (a gist or similar).
- Agent proposal (not yet accepted): no push listener, because access only
  changes when `pulumi up` runs. At `pulumi up`, one GraphQL query lists
  every org repo with its default-branch head commit; direct dependencies
  are cached per repo and commit, and only repos whose head moved are
  rescanned. This also replaces the ~77 `getRepositoryOutput` calls
  `github.ts` makes on every run today.

## Facts found

- Ruleset bypass actors can only be `RepositoryRole`, `Team`, `Integration`,
  `OrganizationAdmin` or `DeployKey` (`@pulumi/github` 6.13.1); individual
  users cannot be named. Org owners are `grumpy-gorilla` and
  `babieswithaids`; `cheerful-capuchin` is not an owner, so
  `OrganizationAdmin` does not match D2. D2 needs a team holding
  `cheerful-capuchin` and `grumpy-gorilla` as the bypass actor.

## Open questions

- Push listener vs head-commit cache at `pulumi up` (agent recommends the
  cache).
- Whether the cached dependency list is committed to infra (visible,
  reviewable) or kept local.
- Confirm D1 reading: contributors get push on every repo their project
  reaches, including shared libraries, and can push to main on the
  non-restricted ones.

## Implementation draft (2026-10-07, agent choices, not reviewed by the user)

Files: `infra/infra/github.ts` (rewritten), `infra/infra/lib/github-dependencies.ts`
(new), `infra/infra/lib/github-file.ts` (gh helpers exported),
`infra/infra/github-dependencies.json` (generated, tracked).

- Levels named `viewer` / `contributor` / `maintainer` (pull / push / maintain);
  teams `<group>-viewers|contributors|maintainers`.
- `*.<level>` maps to one org-wide team `all-<suffix>` instead of one team per
  group, to keep the TeamRepository count near the repo count.
- Each repo belongs to exactly one group; the program throws on duplicates.
  Repos the user did not place went to a draft `platform` group; venue repos
  (cme, cbot, nymex, comex, cme-globex, venue-core, databento-mkt-data,
  hist-data-common, market-info-server) went to `marketdata`. Service groups
  web, backtest, sim-gw, event-gw, realtime-gateway, monitoring kept.
- Draft bindings: Capuchin `*.maintainer` + `engine.maintainer`; Gorilla
  `engine.maintainer`; Marmoset and Nilgiri `*.viewer` + contributor roles
  matching their old teams; Sifaka `strategies.viewer`.
- Rulesets only on group repos (same set as the old `Repo` registry plus
  `monitoring`). PR ruleset only on `requirePullRequest` groups (engine), bypass
  actor = `engine-maintainers` team.
- Resolver: one GraphQL page query for all repo heads, REST recursive tree per
  repo whose head moved, manifests read in bulk GraphQL (100 per request);
  cache in the OS temp dir keyed by head commit. Cold run ~25-60 s, warm run
  one request.
- Finding: manifests reach nearly every repo from any Rust root (for example
  `messaging`'s package.json references structure-web and
  application-server-client), so dependency-based read grants cover almost
  everything.
- Finding: the old `MEMBER_ONLY_REPOS` check compared Pulumi Outputs by
  identity and never matched; contributors had push on every repo in their
  project lists.
