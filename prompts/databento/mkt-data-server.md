## Requirements
- do NOT implement anything unless asked for
- you have max 500 words per question reply (excluding code)

## Context
We need the live CME data for our trading infrastructure. For now, we're going to use databento as the data provider (https://databento.com/docs/schemas-and-data-formats/mbp-1?historical=rust&live=rust&reference=rust).
They already have the [rust SDK](https://docs.rs/databento/latest/databento/).
We already have the concept of a [data feed](knowledge-base/docs/references/data-feed.md) and there is one declared for some of the databento mkt data - data-feed-definitions/rust/crates/codecs/data-feed-codec-dbn-0c63c4bb575d62b5f4552458559baf0d.
However, in order to use that data, we need some kind of mapping between the databento properties and our domain properties.
For now, the only one that we care about is `instrument_id`.
See instrument: market-info-core/rust/src/entities/instrument.rs.
The list of the instruments is stored in the mkt info repo: market-info/crates/market-info-repo.

For the demo purposes, we want the simplest mkt data server.
Ideally, it should:
1. fetch the market info
2. put mkt info in the repo
3. create the client that subscribes to the necessary dataset (based on the config)
4. list all the instruments in the mkt info that match the dataset
5. build a lookup table between the symbols and the instrument ids
6. subscribe to all the symbols from those instruments
7. when receiving data, resolve the instrument id and publish the raw bytes to the right NATS topic

### config
Following the conventions from the dev-docs/frameworks, we'll use the YAML config and load it at startup.
It should include something like (you're free to improve it)
```rust
pub struct MktInfoQuery {
    pub venues: Box<[Venue]>,
    pub instrument_types: Box<[InstrumentType]>,
}

pub struct Dataset {
    ///
    /// # How to discover
    /// ## Check the rust client enum
    /// https://docs.rs/dbn/latest/dbn/publishers/enum.Dataset.html - Databento datasets
    ///
    /// ## Query
    /// ```
    /// use databento::HistoricalClient;
    ///
    /// let mut client = HistoricalClient::builder().key_from_env()?.build()?;
    /// let datasets = client.metadata().list_datasets(None).await?;
    /// for id in datasets {
    ///   println!("{id}");
    /// }
    /// ```
    //
    pub id: Arc<str>,
    pub mkt_info_query: MktInfoQuery,
}
```


### market info
I think we'll have a static rkyv-encoded file with the market info, a feed resolver and codec that knows how to decode the data.
The handler will just put the data into the market info repo. If built properly, when we add the dynamic mkt info, we will just move the handler into a different place

### databento client
based on the config, we'll create the client for the necessary dataset.
Then, based on the mkt info query we'll .iter() market info repo and filter instruments based on the query.
Then, we can get Instrument.symbol
Ideally, we should verify that all the symbols exist
We'll get the `code=SymbolResolutionFailed` error during subscription https://databento.com/docs/api-reference-live/basics/symbology?historical=rust&live=rust&reference=rust

### Out of scope
Dynamic subscription and market update

## Questions

### 1. How would you store the market info data?
I want to have a human-readable one file per market format using [ron](https://github.com/ron-rs/ron)
and one rkyv-encoded binary file that will be loaded when any program requiring mkt info starts up
Ideally, then, the concept of StaticMktInfoRepo goes away, and we just have a market info repo.
Maybe we don't need the files and use some kind of database, idk for now, but ideally, I want to be able to edit the mkt info by hand,
then update the file and just remount that file to the program


---
Read brainstorm/reports/mkt-info/storage.md.
Implement the readonly market info repo in the market-info/crates/market-info-repo/src/readonly module.



