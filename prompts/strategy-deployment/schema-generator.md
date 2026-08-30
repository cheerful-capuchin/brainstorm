## Context
- new schema: knowledge-base/docs/decisions/records/DEC-0ADYZ-strategy-deployment-feed-storage-demo.md
- old schema: timeseries-db/clickhouse/schema.sql
- generator: event-gw/crates/db/ch2rs/README.md

Currently, whenever I want to describe the clickhouse schema, I have to manually write down all the SQL DDL and then I generate the types
from it.
However, this manual table definition introduces issues of human-error. I prefer using something like drizzle orm
where I build the tables using typescript and if the code needs repetition, I just write a for loop instead of having to copy it all the time
in the SQL file.

Ideally, I want the state of the schema now, and the sql is just a sidecar.
For instance, with drizzle orm you can do the following: structure-web/packages/app-db/src/schema.ts.
Custom functions, proper code organization, type checking, etc. However, drizzle doesn't support clickhouse.

There is something like https://www.effect.website/docs/v4/api/sql-clickhouse/ClickhouseClient.
Would I be able to
