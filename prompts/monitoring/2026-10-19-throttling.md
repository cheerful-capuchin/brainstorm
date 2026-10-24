Over the weekend we received a flood of alerts.

I don't want to get pinged every 5 minutes in Discord about alerts.
How can we update the monitoring/rust/crates/notify-gw/src, so there is a throttling of the similar events
AND I can send some kind of message for it to shut the fuck up?

---


SESS-00R0FYF-notify-gw-alert-flood-throttle-and-bursts.md

Let's talk storage. If we're posting the digests to alerts, we cannot lose information.
I think it's reasonable to re-use the clickhouse cluster to store the alerts there.
I think creating a new database with its schema within the same cluster is reasonable.
That database is going to be managed by the notify gw.
We can later have a cloud agent with readonly access that can give us the alerts in detail.
So, the data is not lost, but we don't get flooded with alerts in discord.

The cadence should also be adaptive, getting pinged every 30 seconds or minute or 5 minutes
is not helpful. I won't be able to react that fast to a burst anyway.

Therefore, there should be a policy of progressive backoff based on the frequency of the data coming in.
if we get event every second, we should compress all of them into a minute and publish them.
If we publish 3-5 consecutive reports each minute, then we should back off to 5-minute intervals.
if we publish 3 consecutive 5-min intervals, then switch to once 20 minutes or something
and then we can go up to an hour.

Storing record-by-record is not useful either. I think I got a pretty good solution in event-gw/crates/event-gw/src/clickhouse_writer.rs.
Where I keep all the buffering logic in the component and then flush a batch once in a while to the database.
I think the egress producer is generic enough for it to be placed in ./timeseries-db/rust/crates/...

What are your thoughts and ideas?
What are the solutions and trade offs?
The more options we exhaust, the better

## Response to SESS-00R0FYF-notify-gw-alert-flood-throttle-and-bursts.md

### Failures
**Failures need the opposite of event-gw's policy.** event-gw tries 3 times, then drops the batch (it calls this "demo durability"). For alerts:

- Network or server error: retry in the process while holding the tickets (the SDK keeps extending the leases). After N tries, nack, and the 10 s–600 s retry policy already in infra takes over.
- Client error (these bytes will never insert): nack, plus a dead letter policy on the subscription. That is the only way to stop a bad batch from looping without dropping it. You could also retry row by row so only the bad row ends up dead lettered.

Agreed, we need to have a distinction between different kinds of errors.
I think the current event-gw/crates/event-gw/src/clickhouse_writer.rs:85 handles it in some way, but I don't think it exposes the error properly
for us to react accordingly

### Backup
Don't copy event-gw's `BackedUp` path - yeah, that route is deprecated, we should not use it.
If we start having the reliability problems: first, we have pub/sub. Then, we can start thinking about
something like WAL in the gcs.

### Ack
I think we need the discord alerting be independent from the persistence.
It may be that the persistence layer itself is compromised, ideally, we should send alert about that too.

### Schema
Yeah, probably having 2 different tables is fine.
How many consumers use the Alert feed right now?
I don't like this service_name
