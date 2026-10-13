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
