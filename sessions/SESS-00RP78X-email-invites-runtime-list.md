---
create_time: 2026-10-27T16:49:33Z
title: "Email sign-in with a dynamic invite list"
summary: "Invites gate new registrations only; existing users keep access after removal. Drop credit-deposit gate. Dynamic storage without redeploy required; bucket file vs database still open."
related_sessions:
  - SESS-00PH0TQ
  - SESS-00PHDEJ
  - SESS-00PM9HX
  - SESS-00RP78Z
agents:
  - codex:01a17e43-bf8a-7402-a069-d1002b0c3ebe
---

# SESS-00RP78X: Email sign-in with a dynamic invite list

## Scope and coordination

STXR Engineering; structure-web authentication and infra. Research/design discussion, not implementation. Shared record for this conversation; other agents should join this record before writing and avoid creating duplicate records.

## User constraints (2026-10-27)

- Add email sign-in; only emails in the invite list should be allowed.
- Invite changes must take effect without redeploying the application.
- Remove the credit-deposit eligibility check in AuthService.verifyChallenge; replace it with an injected eligibility policy/source.
- Explore a file in a bucket reloaded by the running application, inspired by game asset hot reload. Pulumi ownership is a question, not a decision.
- Co-founders need a simple way to view and change the list; evaluate existing tools/MCP versus custom CRUD and permissions.

## Relationship to prior decisions

- SESS-00PH0TQ accepted email OTP, dropping credit deposits, and a database allowlist. This conversation explicitly reopens storage; no replacement storage decision has been made.
- SESS-00PHDEJ proposed SignUpPolicy.admit and an invitation module; those were agent proposals, not accepted decisions. Its open-signup fallback must not be assumed for an invite-only deployment.
- SESS-00PM9HX requires new service logic in Rust, schema managed by drizzle, and queries through egress. A storage-only adapter does not automatically resolve the scope of that requirement.

## Open questions

- File, database, or another source; editing UI/tool; propagation delay and maximum tolerated staleness.
- Plain membership list versus consumable invitations with expiry, organization membership, or role grants.

## Decision: invitations gate registration only

User answered explicitly: "Block new registrations only; existing users keep access."
Removing an email from the list therefore does not block that existing user's sign-in or refresh and does not revoke existing sessions. Check admission only after credential proof and account lookup establish that a new account is needed. This resolves the broader wording in the opening request.

## Parallel session

SESS-00RP78Z was created concurrently by claude-code:bbf40f1c-45a6-4d85-b9c8-52c5f62708f3 for the same opening question. Cross-reference its findings; this record contains the subsequent explicit registration-only answer.

## Research findings

- Current verifyChallenge returns signIn for existing users before the creditDeposits gate (auth-service.ts:227-255). Both REST and binary execute transports call the same AuthService. The replacement belongs at that shared boundary.
- iam-core TS and Rust currently support only the Solana identifier kind. Email identifiers, consistent canonicalization, OTP proof verification, and email delivery remain separate work; an invite list alone does not add email authentication. Identity IDs hash the kind and raw value bytes. No implicit email-to-wallet account linking.
- Existing config is read once (rt-config.ts:990) and the Pulumi Cloud Run revision annotation hashes its content (infra application-server.ts:434). Keep mutable invites out of that object/hash.
- Configured Cloud Run CPU is always allocated (cpuIdle:false), min instances 0/max 1. Initial loading remains necessary; overlapping revisions can each hold a snapshot. No live cloud settings were checked.
- Existing GCS getObject exposes generation and downloadObject reads bytes. Prefer authenticated API reads over relying on FUSE filesystem watch events.
- Existing config bucket readers include unrelated workloads; use separately restricted storage for email addresses.
- No invite/whitelist records found in the current knowledge-base catalog. REF:iam describes existing wallet challenge and refresh behavior. Knowledge base unchanged.

## Recommendations under discussion, NOT user decisions

- A small private GCS JSON membership list is sufficient for this registration-only scope. Pulumi owns infrastructure/IAM/source URI, operational tooling owns contents.
- Simplest refresh at low signup volume: on admission, reload if no snapshot or its successful validation is older than a chosen TTL (e.g. 30 seconds); coalesce concurrent reloads. A periodic poll may later reduce request latency. No runtime code/plugin reload required.
- Parse the entire document into an immutable normalized identifier set before swapping it. Keep the GCS generation attached to the snapshot and admission record. Use a single consistent snapshot per check; serialize reload publication.
- No valid fresh snapshot means registration temporarily unavailable, never open registration. Existing users bypass this policy and retain sign-in/refresh access. A stale-grace allowance would need a deliberate limit; otherwise reject after TTL if refresh fails.
- Tooling can be a small list/add/remove CLI, optionally exposed over MCP, using personal/cloud identities, schema validation and conditional writes. ifGenerationMatch prevents lost edits. Enable DATA_WRITE audit logs and object versioning with suitable retention. File storage does not eliminate permissions.
- A private Google Sheet read through the same source port gives co-founders a familiar editor; avoid building a Sheet-to-GCS synchronization pipeline initially. Existing Postgres plus a narrow admin tool is a valid alternative and does not require building a full CRUD UI or completing the entire RBAC design. Prefer DB for consumable/expiring invitations, grants or transactional acceptance.
- Application owns SignUpPolicy/admission contract. GCS reader performs I/O and parsing; snapshot/cache is a separate concern under repo adapter conventions. New business-policy logic should respect SESS-00PM9HX's Rust direction; existing TS orchestration and infrastructure can host it.
- Flow: verify proof -> resolve user -> existing user signIn; absent user -> admission decision -> create -> signIn. Gate verifies the identifier proven by OTP, not arbitrary request email. Recheck eligibility at verification; an early send-time check is optional optimization/abuse control and never sufficient. Missing policy must deny admission.
- Verification scenarios if implemented: removed invite before OTP verification, uninvited email, existing user after removal, malformed/missing/unavailable source, refresh race, concurrent edits, same canonical email identity, OTP replay/attempt limits, and both API transports.

## External evidence

- https://docs.cloud.google.com/storage/docs/consistency — strong reads and atomic single-object replacement; client caching still determines propagation delay.
- https://docs.cloud.google.com/storage/docs/request-preconditions — conditional reads, generation-bound downloads and lost-update protection.
- https://docs.cloud.google.com/storage/docs/audit-logging — DATA_WRITE audit logging must be enabled explicitly.
- https://www.pulumi.com/docs/iac/concepts/resources/options/ignorechanges/ — ignoring changes still requires careful refresh/state ownership; prefer not owning live invite contents in Pulumi.
- https://developers.google.com/workspace/sheets/api/guides/values — direct range reads for a Sheet-backed adapter.
