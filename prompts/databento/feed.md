data-feed-definitions/rust/crates/data-feed-definitions/src/demo/mbp1_book_feed.rs

create the demo mbp1 databento feed
and codec in data-feed-definitions/rust/crates/codecs

I need a feed per mkt data event.
For now, mpb1 is the only thing we care about

You'd have to use the databento lib `databento = "=0.60.0"`.

In the adapter you have to take the mapping table between the databento instrument_id and our domain instrument id
https://databento.com/docs/schemas-and-data-formats/mbp-1?historical=rust&live=rust&reference=rust

