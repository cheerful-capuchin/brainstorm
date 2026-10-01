---
create_time: 2026-10-01T14:31:46Z
summary: "Open: ABAC+RBAC specifics (permission/role definition, iam service vs app server, API key issuance, Pulumi); constraint: internal org must be an ordinary Organization with more grants, no meta-org special case"
related_sessions:
  - SESS-00PH0TQ
---

# SESS-00PHDEJ: Permissions, roles, IAM service, API keys, Pulumi and the organization model

Continues SESS-00PH0TQ. The user wants to turn the accepted RBAC direction
into something specific, and raised one framing concern that shapes
everything below.

## Questions the user brought (2026-10-01)

1. Permissions and roles: how to structure and define them.
2. IAM server: how other services obtain roles and permissions; is this the
   application server's job or a separate iam/auth service.
3. API keys: how to issue internal API keys.
4. Pulumi: how to manage staff permissions and internal API keys from infra.

## Framing constraint stated by the user (2026-10-01)

- Organizations and Projects are coming soon as the resource hierarchy.
- Everything being built to control the application server internally
  (API keys, members, permissions, whitelist) is what any organization will
  want. The user does not want to special-case an internal "meta" org in
  code. Internal scope is only larger: e.g. staff can run the "build strategy
  template" workflow, customers can run deployment and backtest workflows;
  storing the GUI version of the DSL is only for the client app but its access
  model is not different.
- Goal: a model where the internal org is an ordinary org with more grants,
  so multi-tenancy and self-hosting fall out of the same design.

## Decisions

(none recorded yet)
