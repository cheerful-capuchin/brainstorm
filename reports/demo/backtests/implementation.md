context:
- brainstorm/reports/backtest/current.md

I want to have the detailed implementation plan for the backtest simulator structure-strat-template-core/src/component.rs in order to satisfy the needs
of the demo and provide the necessary feed knowledge-base/docs/specs/SPEC-backtest-feed.md.

Additionally, there should be a detailed plan regarding the ./backtest-post-processor to read the feed from the file and write the data and metrics to the database.

The place to emit the events is described in the brainstorm/reports/backtest/current.md - `ExecSimulator::on_btest_action`.

The implementation should be built as the vertical slices in order to have something shippable step by step.
I think the simplest start is to update the backtest post-processor to handle the incoming data feed and then output the data
into the dedicated duck db sink.

Then fix the backtest simulator.

Tasks:
## Design the backtest result database schema
assignee: capuchin; estimate = 2 points;

I think it's useful to model metrics as a time series as well.

metrics:
- return %/abs
- high watermark %/abs
- low watermark %/abs
- max drawdown %/abs
- sharpe ratio
- volatility
- trade count
- total fees
- target position changes
- calmar ratio
- sortino ratio
- turnover
- volume
- pnl
- portfolio value

We need to store the backtest data feed events:
- triggering source events
- target positions
- fills
- prices
- runtime events
- fees

## Backtest post-processor config
assignee: marmoset; estimate: 1 point

We're going to use the cloudrun sidecar contrainer for the post-processor, which means it will run in parallel with the main backtest simulator.
Additionally, we're going to use the [Ephemeral Disk Mounts](https://docs.cloud.google.com/run/docs/configuring/services/ephemeral-disk).
Which is an SSD which discards the data after the process is finished.
The backtest post-processor must know which file to read for the ingress messages.
Ideally, there should be a `ephemeral_drive_path` config property that will be a path to the mounted ssd.
This is where all the file operations will be happening, so that it's fast.
However, the `OutputTarget` will have the path to the bucket

```rust
use core::error::Source;
use std::path::PathBuf;
use std::time::Duration;

pub enum BacktestFeedSource {
    ProtoFile { directory: PathBuf, filename: PathBuf }
}

pub struct BacktestFeed {
    pub source: BacktestFeedSource,
    pub retry_timeout: Duration, // how much time to try to get the data from the source

    // future addition. for the sake of the demo we will assume the data feed
    // pub feed_ref: DataFeedRef,
}

pub enum StorageFormat {
    DuckDb { filename_abs: PathBuf }
}

pub struct OutputTarget {
    pub format: StorageFormat,
}

pub struct Config {
    /// [Ephemeral Disk Mounts](https://docs.cloud.google.com/run/docs/configuring/services/ephemeral-disk)
    /// Our target platform is GCP Cloud Run, which doesn't have persistent Disks. Instead, it's either an NFS (network file system) or an ephemeral disk.
    /// We would like to do all the FS intensive work within that mounted disk and then copy the durable artifacts to the NFS (Google Cloud Storage)
    pub ephemeral_working_directory: PathBuf,
    pub backtest_feed: BacktestFeed,
    pub output_target: OutputTarget,
}
```

## Backtest Feed Ingress Producer
assignee: marmoset; estimate: 4 points; blocked by the config task

read the protobuf-encoded file and publish the event to the ingress channel.
Based on the `BacktestFeed` config, we know which directory and file to read.
It may not be immediately available, so we poll it until the `BacktestFeed.retry_timeout` is elapsed.

`DEC-0A5FN: Backtest Feed Emits Raw Economic Events` includes the info regarding the file format.
I'm not sure that the event-based ingress producer is a good approach. I would rather see a tick-based one.
```
loop {
  // Execute all the effects scheduled in the previous tick
  for egress in egress.drain() {
      await egress.execute();
  }
  let ingress_msg = ingress.tick();
  ctx = EngineContext {
      tp: time_provider,
      egress_ch,
  }
  component_host.handle_ingress(&ctx, &ingress_msg)?;        // process and schedule the next effects
}
```



## Backtest Post-Processor Egress Consumer
assignee: marmoset; estimate: 4 points

Write the data to the database. I recommend using the [Appender API](https://duckdb.org/docs/current/clients/rust#appender)
for batch inserts. You can have multiple appenders for the same connection - https://grok.com/share/bGVnYWN5LWNvcHk_1286887b-c4eb-44d8-8adb-c712897c710c

I would design the egress messages in the following way

duck_db/egress.rs
```rust
pub struct ConnectionId(pub u16);
pub mod contracts {
    pub struct AppendRows {
        pub connection_id: ConnectionId,
        pub table: Arc<str>,
        // Basically, we don't want to heap allocate all the time and copy all the parameters and rows, since we're on a hot-path
        // So, ideally, we should have a pool of parameters or an allocator, somehow, once the write is done, we should know and release the
        pub params: Arc<[Arc<[duckdb::types::Value]>]>,
    }

    pub struct Flush {
        pub connection_id: ConnectionId,
    }

    pub struct ExecuteStatement {
        pub connection_id: ConnectionId,
        pub statement: Arc<str>,
        pub params: Arc<[duckdb::types::Value]>
    }
}
```


The backtest post-processor knows where to write based on the `Config.output_target.format`.
Consequently, we can create the database connection in the main function and pass the vec of connections into the egress consumer config, where each index is a connection_id;
duck_db/egress.rs
```rust
pub struct DuckDbWriterConfig {
    pub connections: Vec<duck_db::Connection>
}

pub struct DuckDbWriter {
    pub connections: Vec<duck_db::Connection>
}

impl DuckDbWriter {
    // you may need to either return it as Arc or as a &mut
    fn connection(&self, connection_id: ConnectionId) -> Option<&duck_db::Connection> {
        self.connections.get([connection_id.0])
    }
}
```




