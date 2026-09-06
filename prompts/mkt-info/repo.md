## Context
The public repository contracts are already defined in market-info/crates/market-info-repo/src/repository.rs.

### Testing
market-info/crates/market-info-repo/src/repository/tests/proptests.rs
market-info/crates/market-info-repo/src/repository/tests/edge-cases.rs
market-info/crates/market-info-repo/src/repository/tests/bench.rs
market-info/crates/market-info-repo/src/repository/usage_example.rs

All the utility builders should be at the very bottom of the test files. The most important info is at the top.

The usage_example.rs should clearly explain how to use the repo in many use-cases. It's more about showing the capabilities than testing anything.
Therefore, the example should be rich in different use-cases. You have to explicitly specify that the file is the examples AND
you should document the intent and the use-case in human language. It should be simple techinical English.
The examples should include the creation, initialization, reading codebase, insertion codepath, how to react on failures.
You have to reall think hard before making an example.

The tests/proptests.rs should be things that actually verify the behaviour. There, we should rely on the proptest to have different combinations of data and exercise different codepaths.
For the tests/edge-cases we should specify a test per edge case if they are present. We don't need many tests there, I much prefer having one or two tests, instead of a group of useless stuff.

the tests/bench.rs should include the benchmarks regarding different indexes. When do we use a simple array, when do we use the BtreeMap, when do we use the AHashMap

## Task
How would you implement the indexes?
Do you create a file per index kind in market-info/crates/market-info-repo/src/repository/*_index.rs?

## Requirements
- I want you to have at most 300-500 lines per file (except the tests and docs).
- All the prose must be simple technical English
