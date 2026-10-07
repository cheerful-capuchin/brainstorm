---
create_time: 2026-10-08T10:06:41Z
title: "Client app uses the TypeScript domain packages"
summary: "stxr-client-app reuses the TS domain packages (@structure/domain, strategy-core, entity-core, telemetry...) through a rolldown bundle + .d.ts committed in the client repo, imported as @structure/client/<package>/<path> (package renamed from @structure/client-core); builds from local checkouts, no push needed; implemented (uncommitted) with a deterministic declaration program; Rust client-core move deferred; gcp Run stays in strategy_deployment.ts; DSL import stays; stxr-domain-codegen now matches qualified DomainId/HashId derives and fails on id attrs without a derive; ContractID TS generated"
related_sessions:
  - SESS-00Q1QZV
  - SESS-00P9RZK
---

# SESS-00Q3CHH: Client app uses the TypeScript domain packages

Started from SESS-00Q1QZV (backtest severity mapper in the client).

## D1: Fix the TypeScript duplication first

The client app (`stxr-client-app`, VS Code fork) hand-writes types that the
TypeScript domain packages already define: ids (`DomainID`, `*_id.ts`),
`StrategyDeployment.Status`, `StrategyRevision.Status`, telemetry `Severity`
and `SourceType`. The user wants the client to use the domain packages listed
in the workspace `pnpm-workspace.yaml`.

Rejected for now: moving query building and row decoding into the Rust
`client-core` WASM crate (query in Rust, I/O in the VS Code host). The user
called it too much work. It is deferred, not rejected as a design.

Note for later: SESS-00P9RZK moves the client ClickHouse queries into event-gw,
so the ClickHouse part of a Rust client-core move would not apply.

## D2: Consume the domain packages through one committed bundle in the `client` repo

Accepted ("the idea is sound"). Nothing is implemented yet.

- A package or subpath in the `client` repo (for example
  `@structure/client-core/domain`) depends on the domain packages through their
  pnpm `git+ssh://...#path:` specs and re-exports only what the client needs.
- esbuild bundles it (ESM, node platform) and one `.d.ts` is emitted from the
  packages' own tsconfig. The output is committed, like the client-core WASM
  build.
- The package lists `zod` 4.4.3 as its own dependency so its declarations
  resolve zod 4 (the app's top-level zod is 3.25.76), as `api-client` does.
- The app imports it from Electron main code, uses `import type` elsewhere, and
  sends strings over IPC (VS Code IPC is JSON; `DomainID` has `toJSON`, other
  bigints throw).

Why a bundle, from the investigation:

- The app uses npm; the domain packages reference each other with pnpm's git
  subdirectory specs, which npm cannot install.
- The packages ship raw `.ts` with runtime namespaces; Electron's Node does not
  run `.ts` from `node_modules`.
- The packages use `strict: false` and lib `ESNext`; the app's
  `src/tsconfig.base.json` is strict with `noUnusedLocals`,
  `noImplicitOverride`, lib `ES2024`. Raw sources fail its typecheck (12
  errors for the id modules alone, 36 with three entity modules);
  `skipLibCheck` only covers `.d.ts`.

Rejected alternatives (not chosen by the user, listed as considered): adding
every domain repo as a submodule with npm overrides; moving the VS Code fork
to pnpm.

## D3: Keep the Cloud Run import in `strategy_deployment.ts`

`strategy-core/ts/src/entities/strategy_deployment/strategy_deployment.ts`
imports `Run` from `@structure/gcp/run/mod.ts`, which pulls `undici` and
`jose` into a bundle. The user keeps it: they may use gcp primitives on the
client. Do not propose moving it for bundle size.

## D4: Keep the DSL import in the strategy revision path

`strategy_revision.ts` -> `strategy-variables.ts` -> `@structure/dsl-compiler`
stays. The user rejected moving it ("Definitely not"); no reason given.

## D5: The TS ContractId should be generated

The user wants `ContractId` (`cntr_`) generated into
`market-info-core/ts/src/entities/contract/`. It is missing today.

Cause: `stxr-domain-codegen` (`domain/crates/domain/codegen/src/parse.rs`,
`entity_id_derive_kind`) matches derives with `path.is_ident("DomainId")`,
which only matches a single-segment path. `contract.rs` writes
`stxr_domain_derive::DomainId`, so the struct is skipped without an error.
`instrument.rs` uses the same qualified form; its TS files exist only because
they were last written in market-info-core commit 3b576de (2026-05-01) and the
generator never deletes files, so they are no longer regenerated.
`market-info/src/tick_table.rs` also uses the qualified form, but that crate
has no codegen build script.

Fix chosen by the user: options 1 and 2, in the generator. Rejected: importing
`DomainId` in the entity modules instead (the next qualified derive would be
missed again).

1. The derive matches on the last path segment, so `DomainId`,
   `stxr_domain_derive::DomainId` and `::stxr_domain_derive::DomainId` (same for
   `HashId`) are all found.
2. A struct with `#[domain(...)]` or `#[hash_id(...)]` but no recognised derive
   fails generation instead of being skipped.

Done 2026-10-08, uncommitted, in `domain/crates/domain/codegen/src/parse.rs`
(`path_ends_with`, `entity_id_attribute_name`, two table tests). The fixed
generator over all six crates using it (market-info-core, accounting-core,
strategy-core, entity-core, workflow-core, iam-core) raises no new errors. Its
only new output is `market-info-core/ts/src/entities/contract/`
(`contract.generated.ts`, `contract_id.ts`), written by a build of
market-info-core through the workspace domain patch and left untracked. The
instrument TS regenerates byte-identical.

## D6: No push needed to build the bundle

The user: pnpm resolves the domain packages from GitHub or from local
revisions. Add `stxr-client-app/client` to the root `pnpm-workspace.yaml`
packages so the root `link:./...` overrides apply; the bundle then builds from
the local checkouts (unpushed changes included). Pushing matters only before
someone else rebuilds the committed bundle from the `client` repo alone, where
the git specs resolve against GitHub `main`.

## D7: rolldown + rolldown-plugin-dts, package renamed to `@structure/client`

- Build with rolldown and rolldown-plugin-dts (the user uses rolldown already;
  `application-server/crates/application-server-core/rolldown.config.ts` is the
  precedent). Unlike that config, the `@structure/*` packages are inlined, only
  `zod` stays external, and declarations use tsc rather than `oxc: true` (the
  domain sources lack explicit export types).
- The `client` repo package is renamed from `@structure/client-core` to
  `@structure/client`.

## D8: Subpath per domain package, mirroring the original layout

The user prefers option 1:

```ts
import { StrategyDeploymentID } from "@structure/client/strategy-core/entities/strategy_deployment/strategy_deployment_id";
import { Severity } from "@structure/client/telemetry";
```

- One installed package, one copy of each shared module (zod, `@structure/core`),
  rolldown multi-entry or `preserveModules`, exports map with one entry per
  domain package (`"./strategy-core/*"` -> js + d.ts).
- Rejected: a single flat root import (the user asked for imports that read as
  separate packages).
- Not chosen, can be added later on top of the same bundle: thin `file:`
  packages under the real names (`@structure/strategy-core/...`).
- Not workable: tsconfig `paths` alone; VS Code dev runs the compiled JS
  through Node, which ignores tsconfig.

## Spike result (2026-10-08, temp dirs only, no repo changes)

rolldown 1.0.0-rc.12 + rolldown-plugin-dts 0.23.2 + typescript 5.9.3 (the
workspace `typescript` is 7.0.2, which has no JS API for the plugin), one named
input per subpath, shared chunks in `_chunks/`, `zod` external:

- Works. A consumer built with the client app's `tsc` (7.0.2) and
  `src/tsconfig.base.json` plus `skipLibCheck` typechecks, including a branded
  id mismatch caught by `@ts-expect-error`; zod 4 resolves from the package
  while the consumer's top level has zod 3.25.76. Runtime: ContractID round
  trip, wrong prefix -> `DomainID.Err` 3, `JSON.stringify` gives `cntr_...`.
- Required settings: `dts({ tsconfig: false, resolver: "tsc", eager: true,
  compilerOptions: { strict: false, strictNullChecks: true,
  allowImportingTsExtensions: true, module/moduleResolution NodeNext, lib
  ESNext+DOM, skipLibCheck } })`. Without `eager`, 10 declaration files fail
  to emit and `Result` degrades to `undefined<...>`.
- `//#region` comments embed absolute source paths; an output plugin with
  `renderChunk` stripping `//#region`/`//#endregion` lines removes every
  `/Users/` occurrence.
- Exports map used: `"./*": { "types": "./dist/*.d.ts", "default": "./dist/*.js" }`.
- JS output is about 1075 KB, `strategy_deployment.js` alone about 913 KB
  (gcp/undici, kept per D3). Its `.d.ts` imports third-party types (ky, luxon,
  @hapijs/bourne, isomorphic-unfetch, node builtins) that the app does not
  install; under `skipLibCheck` they silently become `any`.

TypeScript versions (follow-up): the client app already typechecks with
TypeScript 7 (`@typescript/native` 7.0.2 provides `tsc`) and keeps
`typescript` = `npm:@typescript/typescript6@^6.0.2` for the JS API (build
scripts, eslint). The bundle build needs the JS API too: rolldown-plugin-dts
tsc mode works with `typescript@npm:@typescript/typescript6@6.0.2` (same
result as 5.9.3). Its experimental `tsgo` mode with the TS 7 binary fails: the
plugin forces `rootDir` to the tsconfig directory, and the linked domain
sources live outside it (TS6059).

## Implemented (2026-10-08, uncommitted)

`client` repo (the `stxr-client-app/client` submodule; the workspace-root
`client` checkout is stale and was not touched):

- Package renamed `@structure/client`; exports `./domain/*`, `./entity-core/*`,
  `./iam-core/*`, `./market-info-core/*`, `./strategy-core/*`, `./telemetry`
  pointing at `ts/build`; `dependencies: { zod: 4.4.3 }`.
- `ts/` build package `@structure/client-bundle` (devDependencies: the six
  domain packages by git spec, rolldown 1.0.0-rc.12, rolldown-plugin-dts
  0.23.2, typescript = @typescript/typescript6 6.0.2). Registered in the root
  `pnpm-workspace.yaml` so the local links apply.
- `ts/rolldown.config.ts`: one input per exposed module (13). Before the build
  it runs a JS-only rolldown pass to list every TypeScript module, creates one
  tsc program with all of them as roots, emits each once in sorted order, and
  pushes it into `rolldown-plugin-dts/tsc-context` `globalContext`. Reason:
  `eager` built a program per module (4 GB, OOM), and the union member order
  in declarations changed between builds. Now about 0.8 s, 0.8 GB,
  byte-identical over 8 builds.
- justfile: `install-ts`, `build-ts` (rebuild + stage), `verify-ts-bundle`
  (fresh build into a temp dir must equal `ts/build`; no `/Users/`, `/home/`,
  `C:\Users` paths), `check-ts-bundle`; `fmt-ts-bundle` is a no-op (no
  formatter set up).

App (`stxr-client-app`): every `@structure/client-core` became
`@structure/client` (package.json, the lockfile's 3 entries edited by hand
because local npm also stripped `libc` fields, import map, `stxrClientCore.ts`,
market info, price and valuation imports, release script); the macOS packaging
in `build/gulpfile.vscode.ts` also copies `ts/build/**` and
`node_modules/zod/**` of the package. `node_modules/@structure/client` symlink
created, `client/node_modules/zod` 4.4.3 placed as npm would.

Verified: app `tsc` (7.0.2) has 57 errors, all pre-existing api-client/stxr-ui
drift, none in changed files; a probe importing the subpaths typechecked
(brand mismatch caught). Runtime from the app root: subpaths, telemetry, WASM
initSync + market-info catalog (697 summaries). Without `client/ts/node_modules`
the bundle resolves `client/node_modules/zod` 4.4.3.

Follow-ups not done:

- `realtime-gateway/ts/dashboard` depends on `@structure/client-core` from
  client.git main and imports it in 8 files; it breaks once the rename is pushed.
- A standalone `pnpm install` in `client/ts` (outside the workspace) resolves
  the domain packages' own git specs; several point at
  `entity-core.git#path:/ts`, which does not exist (the package is at
  `/packages/entity-core`).
- The root `pnpm-lock.yaml` install also re-resolved some unrelated peer
  versions (bufferutil/utf-8-validate under expo and drizzle).

## D9: Expose every module, not a hand-kept list

The user questioned the 13-entry list (an unlisted path fails to resolve,
which defeats D8). Now `ts/rolldown.config.ts` generates one input per module
of `src/` (tests and `.d.ts` excluded) for the packages in
`packagesWithSubpaths` (domain, entity-core, iam-core, market-info-core,
strategy-core) plus `telemetry/index` for `@structure/telemetry`: 75 entries,
1.4 s, 0.84 GB, byte-identical across builds, 2.2 MB output, all 75 load at
runtime from the app.

Bug found on the way: the program roots came from a JS-only rolldown pass, which
never loads type-only modules (`export type * as TradingAccountEvents` in
data-feed-definitions), so their declarations failed to emit with only a
plugin warning and the types became `any`. Roots now come from a TypeScript
program over the entries. Guards: priming fails if a root emits nothing; the
program's `emit` is wrapped so any emit during the build that writes nothing
fails `buildEnd`; a second program in the plugin context also fails. Tested by
leaving `data-feed-definitions/src/lib.ts` out of the roots: the build fails and
names it.
