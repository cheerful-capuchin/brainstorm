create the session file

You can read what a data feed is in the data-feed-core and in the knowledge base.
There has been some work with data feed definitions in the prototypes/data-feeds-code-generator.
Additionally, we've been handrolling the feed codecs in data-feed-definitions/rust/crates/data-feed-definitions.

Now, I have to make love between all those three:
- data feed core
- data feed prototype
- data feed definition

we need a catalog of the market data feeds, similar to how we handle market info (market-info/assets).

There are a couple of things that are currently missing.
First, there is no canonical data feed id.
If you look at the handrolled data feed version for the demo, we have an idea of a data feed kind id and data feed subject id
together, they compose into the data feed id.

Moreover, the shape of the data feed is should be done as a template and then all the data feed instances with subjects
should be generated into a single binary file that the client of feed info server can read and distribute.

There are a lot of questions on how to make it work. I think the first one I would like to ask is how do we declare the definitions
of a canonical feed, e.g. Databento MBP1 Feed

This feed has a known subject structure - instrument id; known shape - Mbp1BookUpdate and Trade;
known vendor and semantic meaning of each event that comes in.

I would like to get rid of that disgusting hardcoded pub static DATABENTO_MBO_FEED in data-feed-definitions/rust/crates/data-feed-definitions/src/demo/databento_mbo_feed.rs
and instead have the definition using the core types.

This immediately triggers many questions:
- where do we define this shape
- how to we define it - using rust objects or some kind of DSL?
- how does the code have access to it or does code always rely that the data feed info will be passed in a config
- how do we link the data feed definition with the codec
- how do we distinguish the shape of the data that comes in vs the semantic trait/view that we apply to that data?


--><---

SESS-00QGNFK

let's go step by step. I think a RON file is the way to go, and then we'll codegen rust, where the feed it will already be computed.

Regarding event, I like the current MarketDataEventDefinition, where we have kind that explains the semantic meaning behind this event, cadence and then we'll add "shape" that will point to the actual shape of the message/semantic view. Shape declared once can be reused, e.g. OHLCV can have the same shape, but a different bar unit (seconds, minutes, hours, days), bar size (1, 5, 10, 15), bar alignment (UTC, trading session, etc).

Same for a book. A mpb can have 1 level or it can have 10 levels or 50.

I don't think data feed core is used in many spots, so, maybe create a v2 in src where we create all the necessary types and once I approve it and it works, we'll replace all the existing stuff.

Basically, right now I want you to create all the necessary types and define a ron files.

some ron files will include the semantic views. Let's call them "view". then the other ron files will include the events, this is where the semantic meaning kicks in.
then we'll have the formats with all the versioning needed

then we'll have kids with data feed kinds

from those ron files, we should compute all the ids, and generate all the rust traits, structs, ids, etc.
I think the generator should live in data-feed-core/rust/crates/

for now, let's generate everything in data-feed-definitions/rust/crates/data-feed-definitions-v2
and the source ron files will be in the data-feed-definitions/definitions

Let's start simple:

OHLCV from databento
bar unit: second, minute, hour, day
bar size: 1
bar alignment: utc

databento schema
```
<table class="md-table" style="width: 100%; min-width: 100%;">
<thead>
<tr>
<th>Field</th>
<th>Type</th>
<th>Description</th>
</tr>
</thead>
<tbody><tr>
<td><code class="inline-code">ts_event</code></td>
<td>uint64_t</td>
<td>The inclusive start time of the bar aggregation period based on the <code class="inline-code">ts_recv</code> from trade messages expressed as the number of nanoseconds since the UNIX epoch.</td>
</tr>
<tr>
<td><code class="inline-code">rtype</code></td>
<td>uint8_t</td>
<td>A sentinel value indicating the record type. Can be 32 (<code class="inline-code">OHLCV-1s</code>), 33 (<code class="inline-code">OHLCV-1m</code>), 34 (<code class="inline-code">OHLCV-1h</code>), or 35 (<code class="inline-code">OHLCV-1d</code>). See <a href="/docs/standards-and-conventions/common-fields-enums-types#rtype" class="link">Rtype</a>.</td>
</tr>
<tr>
<td><code class="inline-code">publisher_id</code></td>
<td>uint16_t</td>
<td>The publisher ID assigned by Databento, which denotes the dataset and venue. See <a href="/docs/standards-and-conventions/common-fields-enums-types#publishers-datasets-and-venues" class="link">Publishers</a>.</td>
</tr>
<tr>
<td><code class="inline-code">instrument_id</code></td>
<td>uint32_t</td>
<td>The numeric instrument ID. See <a href="/docs/standards-and-conventions/common-fields-enums-types#instrument-identifiers" class="link">Instrument identifiers</a>.</td>
</tr>
<tr>
<td><code class="inline-code">open</code></td>
<td>int64_t</td>
<td>The open price for the bar where every 1 unit corresponds to 1e-9, i.e. 1/1,000,000,000 or 0.000000001. See <a href="/docs/standards-and-conventions/common-fields-enums-types#prices" class="link">Prices</a>.</td>
</tr>
<tr>
<td><code class="inline-code">high</code></td>
<td>int64_t</td>
<td>The high price for the bar where every 1 unit corresponds to 1e-9, i.e. 1/1,000,000,000 or 0.000000001. See <a href="/docs/standards-and-conventions/common-fields-enums-types#prices" class="link">Prices</a>.</td>
</tr>
<tr>
<td><code class="inline-code">low</code></td>
<td>int64_t</td>
<td>The low price for the bar where every 1 unit corresponds to 1e-9, i.e. 1/1,000,000,000 or 0.000000001. See <a href="/docs/standards-and-conventions/common-fields-enums-types#prices" class="link">Prices</a>.</td>
</tr>
<tr>
<td><code class="inline-code">close</code></td>
<td>int64_t</td>
<td>The close price for the bar where every 1 unit corresponds to 1e-9, i.e. 1/1,000,000,000 or 0.000000001. See <a href="/docs/standards-and-conventions/common-fields-enums-types#prices" class="link">Prices</a>.</td>
</tr>
<tr>
<td><code class="inline-code">volume</code></td>
<td>uint64_t</td>
<td>The total volume traded during the aggregation period.</td>
</tr>
</tbody></table>
```

It's a prototype, so it's a highly interactive process, we'll rework this and shape it as we go


--><---
Just propose solution, don't modify the code yet

SESS-00QGNFK
It's a prototype, so it's a highly interactive process, we'll rework this and shape it as we go

How do we link the format, codec and adapter to our definitions?
I've already created the example in data-feed-definitions/rust/crates/data-feed-definitions-v2/examples/consume_bars.rs.
It subscribes to the bar feeds from databento (the key is in .envrc in workspace) and hyperliquid.
What I'm missing is the actual decoding and adapter logic.
In both cases, the adapter has to be stateful, since the domain instrument is a lookup in a table.
You probably need to add the market status event to handle the databento properly. Please don't do any hacky shit with arc and mutex.
Somehow, the adapter needs to know the status of the databento markets.

## Task
Propose, how we extend our current definition of the feeds, so we can link the codecs and adapters?

The databento codec already exists in data-feed-definitions/rust/crates/codecs/data-feed-codec-dbn-0c63c4bb575d62b5f4552458559baf0d.
Even though it does more than decoding the dbn records, it's a good start.

Hyperliquid response is just a JSON record
https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#candle-snapshot
```
[
  {
    "T": 1681924499999,
    "c": "29258.0",
    "h": "29309.0",
    "i": "15m",
    "l": "29250.0",
    "n": 189,
    "o": "29295.0",
    "s": "BTC",
    "t": 1681923600000,
    "v": "0.98639"
  }
]
```

So, somehow from all of this we should be able to create the OHLC view, attach the domain instrument id, and dispatch
each event in to the correct handler.


---

I have the bar feeds from both databento and hyperliquid.
However, there is no use of them right now, 'cause I can't decode anything that comes in.
Here is a common simplified example of the code we'll have
data-feed-definitions/rust/crates/data-feed-definitions-v2/examples/consume_bars.rs

We have the ingress thread that subscribes to different providers to get the mkt data
and we have a component that does something with that data.

https://databento.com/docs/schemas-and-data-formats/ohlcv?historical=rust&live=rust&reference=rust
https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#candle-snapshot

let's say, we're fetching the data straight from the venue.
This adds a complication that we need to map it to our instrument id

With hyperliquid, I think, the market info already tells you the market_idx.
So, you may need to fetch the "universe" in case some info is lacking. But, their request
```
{"coin": <coin>, "interval": "15m", "startTime": <epoch millis>, "endTime": <epoch millis>}
For HIP-3, you need to prefix with the dex name, e.g. "xyz:XYZ100"
```

With databento, you have to first replay the security definitions since the beginning of the week to
have the proper instrument mapping. See databento-mkt-data/README.md

## Task
Let's do the scaffolding first and make it so that we have something for
```
pub fn on_feed_msg(&mut self, ctx: EngineCtx, msg: &FeedMsg) {
    dbg!(msg);
    ...
}
```

Basically, a working example. I don't need the feed mapping right now, I want to see the dbg!() printing the incoming messages
from databento and hyperliquid.

Create simple ingress producers that are working on a separate thread and publish the ingress msg to a bounded channel
