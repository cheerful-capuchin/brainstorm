## Context
- ensure there is a session file created (see the decision-log skill)

In the application server, currently, we have everything tied to a single user. However, we need the organization abstraction and hierarchy.
I've already considered some things when designing the database schema and relationships to not be completely tied to a user.
But it's not perfect.

See:
- structure-web/packages/app-db/src/schema.ts
- iam-core/ts/src/entities/user/user.ts

Currently, the strategies and the trading accounts are attached to the user. Instead, they should be attached to a parent, which is an organization.
In telemetry, I was smarter in making the parent_type an enum telemetry/rust/src/parent.rs.
We're still in the demo stage, so breaking changes are allowed.

What do you think if I add the Organization variant and crate the Organization entity in the domain model?
The strategies and the trading accounts will belong to the org



