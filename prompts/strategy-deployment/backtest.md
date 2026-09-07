dsl-runtime/src/hist_data.rs:828
We have to replace the ArrowFileProvider with the databento file reader.
And instead of parsing the payload and building the tick data
```
// Create and cache HistTickData
let (seq_num, timestamp) = self.create_and_cache_hist_tick_data(timestamp_ns, payload)?;
```
We should just pass the raw bytes as part of the hist data payload.

The on_feed_msg will handle the decoding

Has to be replaced with the databento file parser.
Additionally, we have to get rid of the `pub block_seq: SequenceNumber`, we must order by timestamp here and use the feed_id as a deal breaker


