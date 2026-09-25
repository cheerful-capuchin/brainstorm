You can run the backtest by executing the `run_flip_positions_backtest` command in the structure-strat-template-core/justfile.
The result of the backtest is the backtest feed (binary file) that.
The location of the file is specified in the structure-strat-template-core/strats/flip-positions/strat_config.yaml.
The market data you're going to run with is checked into the git repo by using git lfs
`structure-strat-template-core/mnt/historical-data/databento/GLBX.MDP3/mbp-1`.

You can visualize the data feed, by running the `backtest-feed-stepper` in the data-feed-definitions/justfile repository.
This, however, is for the visual understanding only.

To run the post-processor, ensure that you have the `github.com/stxr-prop/backtest-post-processor/` checked out locally.
You have the `run` command in the justfile.
You need to copy the updated backtest feed file into `backtest-post-processor/mnt/backtests/bt_0VSTTPV0YCXPE/feed.bin` and re-run the backtest.
The output is the duck db database in `backtest-post-processor/mnt/backtests/bt_0VSTTPV0YCXPE/results.duckdb`.
You need the local `duckdb` client installed in order to view that.
Ideally, you should be able to load that file into the `stxr-client-app` and have a visual representation of the backtest run results with all the metrics.
