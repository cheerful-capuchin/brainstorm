do NOT implement anything unless I ask you to
## Context
The public market info contracts are defined in market-info/src/market_info.rs.
Currently, all those markets are generated as code and then are built as a static mkt info repo.
The primary problem there becomes the modification.
We cannot dynamically update the markets. We have to recompile everything.

Instead, what I was thinking is having the markets be stored in market-info/assets/markets in human-readable [ron](https://github.com/ron-rs/ron) format.
We can generate those or edit them by hand. If someone wants to know the info about the market, they can simply look it up.
Additionally, if we group them by venue/instrument_type the navigation becomes simple.
For production, though, we compile all of them in some binary format and store in a bucket or something like that.
Then, when the application boots up, it loads the file and populates the market info repo from market-info/crates/market-info-repo/src/repository.rs.
Additionally, we'll have something like "markets.csv", where we show the computed instrument id based on the market info
```
instrument_id,venue,instrument_type,symbol,filepath
```

The moment our collection changes, we just reupload the markets to the bucket and re-run the service or send some kind of runtime command
that loads the file again and populates the repo.

I don't think that the RON files will store the [MarketInfo enum](market-info/src/market_info.rs).
I think they should store the dedicated struct per venue/instrument_type and then the program that composes the binary production files
builds them all into the enum. This will reduce the unnecessary variance and noise in the Ron files.
The Ron files will NOT include the instrument_id.

Then, for the market info generators, they can simply load all those ron files, update the fields they're responsible for and flush the files
back

I think having a program in market-info/crates/mkt-info-gen is reasonable.
I should be a CLI that walks the file tree in market-info/assets/markets, deserializes the objects, builds the MarketInfo enum,
updates the market-info/assets/markets.csv and writes the market-info.rkyv

Naturally, we have a "staging" are before we flush to the disk.

## Out of scope
Ingestion into the market info repo

## Questions
Reply with max of 500 words per question

### 1. Am I missing something valuable from the current idea?

### 2. What is a suitable binary format?

### 3. What data structure is going to be stored in the binary file?
Is that a Vec<MarketInfo> enums that we just load in memory and put into the repo?

## Requirements
- I want you to have at most 300-500 lines per file (except the tests and docs).
- All the prose must be simple technical English


