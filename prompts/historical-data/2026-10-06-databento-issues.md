/Users/doichevkostia/Downloads/downloaded-logs-20261006-131732.csv
databento-mkt-data/rust/crates/databento-mkt-data-download-job

Can you analyze why there were issues with the databento cloud run job?
```
resource.type = "cloud_run_job" resource.labels.job_name = "databento-download-job" resource.labels.location = "asia-northeast1" timestamp >= "2026-10-02T09:16:58.899Z" severity>=DEFAULT textPayload: "[ERR"
```

executions:
- databento-download-job-vq2v9
- databento-download-job-7gfbs

How do we prevent that?
How do we retry?
How do we notify ourselves that there is an issue?

---
Additionally, AFAIK, the default lookback is 7 days, so why does
databento-download-job-fs84b not download the missing data?
'cause I have the backtest error:
```
strat.backtest.failed: err=the historical replay cannot be planned: the historical data file /mnt/historical-data/data/databento/GLBX.MDP3/mbp-1/inst_6DNWS5YM8VQ6R/2026-10-03.dbn.zst does not exist: that day was never downloaded;v=28be3fe766f5620d5769a274fe288b82da15b363;revision=
```

---

Is there some kind of workflow we can build that schedules the databento jobs and then after some time (e.g. 15 min) runs our download job?
We can use the same cloudrun job binary, but pass a different command.

I don't want to waste compute just waiting.

Or do we just run the scheduled timer at, for instance, 9 a.m. that runs command to go schedule the jobs
and then at 10 a.m. to go download the data

What if I want to download the data for the last month, quarter, year?
