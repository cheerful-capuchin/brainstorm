## Context
I have the backtest simulator and the backtest post-processor built. Scan the knowledge base to understand what those are.
We're going to run them as a cloud run job, where the post-processer is a sidecar.
They have the ephemeral disk mount for the communication. The backtest simulator in structure-strat-template-core/src/backtest/host.rs
writes the binary protobuf message file with the backest feed data-feed-definitions/rust/crates/data-feed-definitions/src/demo/backtest_feed.rs

## Context
I have the backtest simulator and the backtest post-processor built. Scan the knowledge base to understand what those are.
We're going to run them as a cloud run job, where the post-processer is a sidecar.
They have the ephemeral disk mount for the communication. The backtest simulator in structure-strat-template-core/src/backtest/host.rs
writes the binary protobuf message file with the backest feed data-feed-definitions/rust/crates/data-feed-definitions/src/demo/backtest_feed.rs
The job is created in the structure-web/packages/api/src/backtests/backtests-service.ts.
The workflow is in structure-web/packages/workflow/src/reducers/reducer-model.ts:178;
The activity worker executing the workflow is in: structure-web/packages/activity-worker/src/jobs.ts

### Workflow
We should reduce the number of steps in the workflow since the backtest and the analysis (post-processing) are the same job.
We no longer need any "statistics" jobs anymore

### Cloud Run Job Template
We should use the backtest post-processor docker image that is built in infra/docker-bake.hcl:207.
The image is already registered in pulumi in infra/infra/docker-repository.ts.
Therefore, when deploying the application server to cloudrun (infra/infra/services/application-server/application-server.ts)
We can easily pass the whole docker image reference to the config.

### Backtest Post-Processor Config
We should be writing the results to the duck db database on the ephemeral disk as well. At the very end of the backtest post-processor,
we should copy the duck db from the ephemeral disk to the dedicated gcs location.
I think we'll use the GS Fuse here to save time and not do the GCS integration

### Backtest Results
Now that the results are a duck db database, they should be served as a raw blob.
I think structure-web/packages/api/src/backtests/backtests-service.ts:1115 still has sqlite there

### Application Server Config
We should pass the backtest post-processor image ref as a config to the application server.
See: structure-web/packages/api/src/app/app.ts, structure-web/packages/api/src/rt-config.ts
And that should be passed as an argument to the strategy build job.



## Task

The first step is to make it copy the duck db artifact from the ephemeral disk to a gcs location.
How would you do that?


can you run a workflow that updates the application server?
The job is created in the structure-web/packages/api/src/backtests/backtests-service.ts.
The workflow is in structure-web/packages/workflow/src/reducers/reducer-model.ts:178;
The activity worker executing the workflow is in: structure-web/packages/activity-worker/src/jobs.ts

### Workflow
We should reduce the number of steps in the workflow since the backtest and the analysis (post-processing) are the same job.
We no longer need any "statistics" jobs anymore

### Backtest Results
Now that the results are a duck db database, they should be served as a raw blob.
I think structure-web/packages/api/src/backtests/backtests-service.ts:1115 still has sqlite there

### Application Server Config
We should pass the backtest post-processor image ref as a config to the application server.
See: structure-web/packages/api/src/app/app.ts, structure-web/packages/api/src/rt-config.ts
And that should be passed as an argument to the strategy build job.

