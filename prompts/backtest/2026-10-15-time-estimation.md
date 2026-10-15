ensure there is a session file present for this conversation (decision-log skill),
note you're working with multiple concurrent research agents
To improve the user experience and our estimations I would like to have an estimation for the backtest run speed.

## Context
We spend approximately 30 micro secs per tick of the backtest, which I saw in the logs in the cloud run jobss.
The historical files are constantly being downloaded.
Once downloaded, they are immutable.
While being downloaded, we could have some additional work done apart from just copying buffers between storages.
We can speculate the duration of the backtest by multiplying the number of ticks available across all the data
files that are in the time range of a backtest by this average processing speed of 30 mics.

There are 2 places I can think about where we need the constant access to the information about the availability and
the quantity of data.
First, the application server. Before submitting the backtest we should validate that all the data feeds
the user has requested actually have enough data in them. If there is no data, we should return the error
and publish an alert, so our customer success can follow up and make a decision whether we need to download the requested data.

Another place, is the client. The AI Agent on the client should have an API to call and understand the availability of the data.

## Task
We need to calculate and store the number of ticks in the file AND the time coverage of that historical data.
I imagine we need to expand the databento-mkt-data/rust/crates/databento-mkt-data-download-job to calculate the info as it's being downloaded.

### Granularity
I imagine we'd want 30-min granularity of the aggregations, since the user may run a backtest
from a custom time range, and I think a 30-min range gives us a close enough estimate.

## Needs refinement
How do we report and store those numbers?
We are definitely not going to have a single file that everyone can mutate in the bucket, since it's a lock and race condition disaster.
Instead, I want full traceability. Ideally, we store the event log and then derive the computed values from there.
I think using analytical database for this kind of data is reasonable.
I think clickhouse is a good candidate for this kind of information.
We don't even have to store the aggregations, since those can be made on the fly.
I'm not sure about the gap detection capability, though.
This is a pure rust implementation, probably in the event gw.

## Communication
I imagine 2 scenarios:
1. We can either write the WAL files in the bucket and have a process collect them
2. Or publish the events to pubsub and let the event gw consume them directly.


Let's brainstorm this

## Q&A

### 1. Can't we estimate the number of databento records based on the size?

### 1. Can't we estimate the number of databento records based on the size?
I think they have a fixed layout, no?

#### 2. Put record_count into the GCS metadata
We're probably going to use the Backblaze B2 as the primary storage for our historical data.
Can we have the metadata there?


### Proposals

####
