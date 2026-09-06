
## Price Tracker
use the trade/crates/trade-core/src/price/tracker.rs
instead of trade_v2/src/mkt_data_manager.rs

## Position Updates
impl<'a, TP, E> TopicMsgHandler<PositionServerAccountUpdate> for ReadyStateNatsHandler<'a, TP, E>

use the data-feed-definitions/rust/crates/data-feed-definitions/src/demo/sim_venue_feed.rs


---
## Context
old:
- strats_v2/src/target_executor/engine_state/venue/uni_gw.rs
new:
- strats_v2/src/target_executor/logic/mod.rs
- strats_v2/src/target_executor/logic/venue/status_update.rs

mockup:
- [Component::on_feed_msg](prototypes/replay/replay_component_mockup/option_a.rs)

Basically, the Handler is just the big context object that primarily includes
the references to the other objects. The handler is created on every new message.
The question I have is how to pass the generics like TP, Egress Msg through this handler?

Basically, I have the handler per each feed message `strats_v2/src/target_executor/logic/venue`
but now I need to fill in the handler with the necessary data for it to work properly.

How do you do that?


## Requirements
- Give me replies with max 500 words per question (code excluded).

---

## Context
In strats_v2/src/target_executor/engine_state/ready_state.rs there is currently a weird routing system of the nats messages.
We want to migrate to the concept of a feed knowledge-base/docs/references/data-feed.md and use the feed-based routing.
However, the feed feature is not fully developed yet and we need to ship the demo.
Therefore, I've already defined some things in the data-feed-definitions/rust/crates/data-feed-definitions/src/demo
and now we just need to integrate them into the target executor.

How would you route and dispatch the feed messages to the right decoders?
For now, we have to hardcode some assumptions, but I was thinking of something like

```rust
impl Component {
    pub fn on_nats_msg(&mut self, msg: &NatsMsg) {
        let mut handler = TargetExecutorHandler {
            // ...
        };

        let result = match msg.subject() {
            DEMO_FEED_SIM_VENUE::subject() => {
                let ctx = FeedContext {
                    feed_id: DEMO_FEED_SIM_VENUE::feed_id()
                };
                self.consumers.simulation_venue.consume_payload(ctx, &mut SimulationVenueProtobufPayloadAdapter, &mut handler)
            },

            _ => ...
        };
        log(result)
    }
}
```
This is, obviously, a sketch that needs alignment. How would you do that?
