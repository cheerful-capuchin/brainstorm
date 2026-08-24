## Prerequisites
The context and the description must be in a very simple language.
The audience is the people with the tech background, they generally understand
what the product is, but they are not aware about much details.
Also, try keeping it succinct so it doesn't take ages to read

## Linear hierarchy
1. **Initiative** — Structure v0 (https://linear.app/stxr/initiative/structure-v0-324e9b736950/overview)
2. **Project** — a major feature
3. **Milestone** — the delivery gate an issue advances
4. **Component label** — the system component affected by the issue
5. **Issue** — a concrete unit of work

## Task
We need to create a Linear project "Data Feeds".
Assign it to the nilgiri. Initiative - Structure v0

### Milestones

Every project uses the same milestones:

- **Designed** — The intended behavior, boundaries, and contracts are captured
  in an accepted DEC or SPEC. Design questions that block implementation are
  resolved.
- **Ready for Integration** — The code is written, reviewed, and verified in
  isolation. Other components can begin integrating with it, but no end-to-end
  integration is claimed yet.
- **Integrated** — The necessary system components use the feature through its
  agreed contracts. The relevant end-to-end paths work.
- **Deployed** — The integrated feature is running in Structure-managed
  infrastructure.
- **Done** — The feature is complete with no remaining work required for that scope.


### Project description

We've already done some high-level concept work on that in entity-core/docs/data-feed/*.md.

The purpose of the data feed is to have a unified interface of representing an arbitrary stream of data.
Moreover, we may let the users define their own custom data feeds. This makes the code and the platform very polymorphic,
since we, the developers, interact with the same API as would the user of our platform.

The pattern "machine-readable feed definition + generated codec + zero-copy field
access" is already how the fastest market-data systems work. However, those are closed sets.
We want to have the universal way to define the message, have a codec that knows how to decode it and dispatch to the consumer.

This allows us to handle many different formats and message shapes through one coherent API.

The project involves multiple tasks:

## Full definition of the feed entity
We should be able to handle the push (subscription) and pull (request) data streams.
Look at the CME and Data Bento

## Code generation
We should be able to generate the encoders/decoders (codec) based on the feed definitions.
Those codecs should take in the handlers and call the dedicated "on_x" functions, where the event is a trait object

```rust
pub trait PriceUpdateView:
HasFeedOrderand<Orderand=BacktestFeedOrderand> +
HasTracing
{
    fn effective_time(&self) -> NanoTimestamp;
    fn subject(&self) -> PriceSubject;
    fn price(&self) -> numerics::Price;
    /// The asset in which the price is represented
    /// For derivative contracts, it's going to be the settlement asset
    /// For the assets, it may be the valuation asset
    fn price_asset_ref(&self) -> DictionaryRef;
}

enum Transport {
    Nats { subject: Arc<str> },
    PubSub { subscription: Subscription },
}

pub struct FeedMessage {
    pub transport: Transport,
    pub bytes: bytes::Bytes,
}

pub struct BacktestResultsFeedHandler<'data, 'handler> {
    pub data: &'data mut Data,
    pub arena: &'handler bumpalo::Bump,
}

impl PriceUpdateConsumer for BacktestResultsFeedHandler {
    type Error = anyhow::Error;

    fn on_price_update(
        &mut self,
        context: FeedMessageContext<'_>,
        message: impl PriceUpdateView,
    ) -> Result<(), Self::Error> {
        let _ = do_price_update(self.data.price_tracker, message);
    }
}
```

## Dymanic and static loading
We should be able to compile the coders statically or load them dynamically, for instance, via a wasm module

## The user should be able to define their own feeds
The interface for adding the data feed definition to the system should be the same internally and for the external users.
Therefore, we need to think about the server and the storage for those feeds.



