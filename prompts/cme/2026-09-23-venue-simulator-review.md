## 1. [OrderSide](venue-core/rust/crates/venue-simulator/src/order.rs)
Why not use the [TradeSide](common/src/side.rs:48)?

## 2. SimulatedVenue
Take in the context instead of "now"
```
pub trait VenueContext {
    fn timestamp(&self) -> NanoTimestamp;
}
```

```
/// The events an order causes: accepted, filled and the account's new
/// positions, or rejected.
fn handle_submit_order<Ctx, Cmd, Mkt>(
    &self,
    ctx: &Ctx,
    command: &Cmd,
    market_info: &Mkt,
) -> VenueEvents
where
    Ctx: VenueContext,
    Cmd: SubmitOrderCommand,
    Mkt: MktInfoRepo;

```

same for handle deposit, withdrawal, apply,

## 3. I don't like that the VenueEvents is a vec that we allocate from within.
I would rather take the allocator/arena from the venue context and return the bumpalo vec or something like https://github.com/zakarumych/blink-alloc.
But maybe you have a better idea

## 4. SimulatedVenue::apply
does it mean it cannot fail? Is this something you took from the tigerstyle?

## 6. I want a more explicit table
venue-core/rust/crates/venue-simulator/src/usage_example.rs:135
// | sell 3 @ 5020   | +1       | 5005          | 15 × 3 × $50 = $2250 |
// | sell 1 @ 5020   | 0        | none          | 15 × 1 × $50 = $750  |

I would like you to use the 5020 - 5005 instead of 15
same in
assert_eq!(realized(&events), dec!(-1000), "-10 points × 2 × $50");
I would like to see the (4990 - 5000) * 2 * $50

## 7. I don't think you need to hardcode the recent client order ids size.
???

##
