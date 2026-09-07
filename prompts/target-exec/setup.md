strats_v2/src/bin/target_executor_bin.rs depends on the environment variable to get its config AND there is no config to be found in the git repo.
Let's fix this by using the clap CLI argument parser, like we do in structure-strat-template-core/src/lib.rs:295

However, instead of just calling the `Args::parse();` pass the args explicitly.

we just need the config option that fallbacks to CONFIG_PATH env var.
Then create the config in strats_v2/mnt/config/config.target-executor.yaml

Ideally, there should be the main function that calls the run function with the args iterator and the main program is created in the `run` function.
This way if I ever need to test it, I can simply call `run(["--config", "some-path"])`;

The market-info is in market-info/assets/market-info.rkyv, from the strats_v2 it's `../` one level up.
prod example infra/infra/services/target-exec.ts.

However, I want the instrument_ids gone



