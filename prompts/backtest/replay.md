structure-strat-template-core/src/replay/mod.rs.
Help me bridge the gap with the data feeds.
We have some ideas in entity-core/docs/data-feed/*.md and knowledge-base/docs/decisions/records/*.md
I have some kind of mock up, but you may want to restructure things.
But basically, the problem we're trying to solve is to codegen all the data encoding and decoding steps, so we just focus on the business logic.
This becomes even more important once we allow our users to build their own strategies and define their own data feeds and subscribe to them.
This codegeneration step becomes increasingly more important.
We'll provide them with tools to build their own strategies, which we'll translate to some custom DSL and then codegen the rust implementation from that DSL.
So, in the ideal scenario we only have to write the business logic between the mkt data and the user's strategy

The current implementation of the codegen in dsl-processor-core/tests/snapshots/generated-strategy.rs is subpar (7K LOC), but I would not concentrate on it yet.
I would like to first bridge the gap for the data feed codegeneration.

How would you solve the problem? Give me a couple of different ideas/suggestions.
Ideally, we want to find the most efficient solution that is also flexible.





structure-strat-template-core/src/replay/mod.rs

We need to have the replay mode for the backtest (see knowledge-base/docs/references/backtest.md).
Currently, it's using the event-based ingress and egress and has to do the atomic locks ( structure-strat-template-core/src/lib.rs:1022)
in order to achieve the synchonization.

However, it doesn't suit the replay, where I prefer the tick by tick approach.
The only issue becomes the question of work. When replaying the events, we want to efficiently fetch them from the flat files,
and efficiently dump the results in the output file.

Ideally, we should be able to leverage the multithreaded CPU and have a bounded thread per core.
How would you organize the reading and writing part so it remains efficient, and we can delay the tick processing in case we're
not flushing fast-enough?

What learnings from ~/work/gh/tigerbeetle can you make in terms of efficient processing?

