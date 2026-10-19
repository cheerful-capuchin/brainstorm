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
