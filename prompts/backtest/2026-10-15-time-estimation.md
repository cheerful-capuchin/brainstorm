ensure there is a session file present for this conversation (decision-log skill),
note you're working with multiple concurrent research agents


To improve the user experience and our estimations I would like to have an estimation for the backtest run speed.

We spend approximately 30 micro secs per tick of the backtest.
The historical files are downloaded and we know for sure how much data there is in there.

I assume based on the time range, we can figure out the number of ticks * by average speed of 30mics
+ some buffer for initialization and post-processing gives us an estimate for the execution time.

How would you calculate and store the number of ticks in the file?
Do we expand databento-mkt-data/rust/crates/databento-mkt-data-download-job to calculate the info as it's being downloaded
and then writing that number somewhere? I imagine it's not a single file in the bucket, since the locking and race conditions
are going to be insane. However, we do need an index of all the downloaded files and ticks in them.

I guess there are several options. We have some WAL and then a single process that merges those entries,
we send the messages to nats when the file is sent to gcp and then there is a collector that maintains either the file
or the database.
Maybe there are better versions, but the goal is to have an index of the files
which time ranges were downloaded,
of them which are empty because there was no activity
consequently, what time ranges are missing and were not downloaded
per each file, how much data there is


Let's brainstorm this
