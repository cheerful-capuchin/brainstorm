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
The list of the instruments should be stored in the mkt info repo: market-info/crates/market-info-repo.
The data is in market-info/assets/market-info.rkyv.

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
use std::path::PathBuf;

pub struct MktInfoQuery {
    pub venues: Box<[Venue]>,
    pub instrument_types: Box<[InstrumentType]>,
}

pub struct Dataset {
    ///
    /// # How to discover
    /// https://databento.com/docs/venues-and-datasets
    ///
    /// ## Check the rust client enum
    /// https://docs.rs/dbn/latest/dbn/publishers/enum.Dataset.html - Databento datasets
    ///
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

pub struct MarketInfo {
    pub location: PathBuf,
}
```


### market info
We'll have an rkyv-encoded file with the market info -> see market-info/crates/market-info-store/src/lib.rs
at startup we'll just load the data into the market info repo (market-info/crates/market-info-repo/src/repository.rs)

### databento client
based on the config, we'll create the client for the necessary dataset.
Then, based on the mkt info query we'll .iter() market info repo and filter instruments based on the query.
Then, we can get Instrument.symbol
Ideally, we should verify that all the symbols exist
We'll get the `code=SymbolResolutionFailed` error during subscription https://databento.com/docs/api-reference-live/basics/symbology?historical=rust&live=rust&reference=rust

Then, we need to map databento symbols to databento instrument id
```
normal market-data records only carry instrument_id in the header. There is no ticker field on trades, MBO, MBP, OHLCV, etc.
You get the venue symbol from side channels:

Live: SymbolMappingMsg — header has instrument_id, stype_out_symbol is the raw ticker. Sent at session start and when a mapping changes.
Definitions: definition records have both instrument_id and raw_symbol on the same message.
Historical DBN: mappings live in the file metadata, not on each record.
Historical CSV/JSON: if map_symbols is on (default), Databento adds a symbol column so you do not have to join yourself. That is an export convenience, not how the live protocol looks.
```
see https://databento.com/docs/standards-and-conventions/symbology#symbolmappingmsg.
Based on the SymbolMappingMsg we know the mapping between the raw symbols that we care about and their instrument_id.
I guess the adapter in data-feed-definitions/rust/crates/codecs/data-feed-codec-dbn-0c63c4bb575d62b5f4552458559baf0d/src/codec.rs has to change


### Data processing
We don't really have to do anything. We can use the data-feed-definitions/rust/crates/codecs/data-feed-codec-dbn-0c63c4bb575d62b5f4552458559baf0d/src/codec.rs.
Just carry the raw bytes together with the message and publish those raw bytes to the necessary nats subject.

### Data feed


### Out of scope
Dynamic subscription and market update

## Tasks

Following the patterns in dev-docs/framework but without having to build an engine, implement the databento.
In databento-mkt-data create the rust/crates/databento-mkt-data-server crate.
You can depend on clap, tokio, databento, and all the necessary crates.

The main logic is very simple -> resolve the instrument id, encode it into the subject, publish to nats

---



