## Context
I'll give you an example of the program where we want to pass in the config and we need a credential - an API key.
databento-mkt-data/rust/crates/databento-mkt-data-download-job/src/main.rs
databento-mkt-data/rust/crates/databento-mkt-data-download-job/src/config.rs
databento-mkt-data/rust/crates/databento-mkt-data-download-job/mnt/config/config.download_job.yaml

In most of our programs, we use a YAML file with some data. However, when it comes to secrets, it's a problem.
We don't want to store the secret right in the YAML file. So far, the workaround I had is to specify the "env var"
where I want to fetch the secret from. However, this leads to either having 2 structs for the config:
1. The raw YAML struct
2. The actual runtime struct with resolved values

Or, the runtime config stores the name of the env var and somewhere, someone, will resolve the variable.
Either way, this sucks.
Ideally, I can declare the config structure, be able to read it from the file of fallback to the env variable.

So, my runtime config would look like

```rust
    #[derive(Debug, Deserialize)]
    pub struct RuntimeConfig {
        pub databento: DatabentoConfig,
        pub datasets: Box<[DatasetConfig]>,

        pub market_info: MarketInfoConfig,
    }

    #[derive(Debug, Deserialize)]
    pub struct DatabentoConfig {
        pub api_key: secret!(Arc<str>, env="DATABENTO_API_KEY")
    }

    #[derive(Debug, Deserialize)]
    pub struct MarketInfoConfig {
        /// The `market-info.rkyv` archive https://github.com/stxr-prop/market-info/blob/main/assets/market-info.rkyv
        pub location: literal!(Box<Path>, env="MKT_INFO_CATALOG"),
        /// Capacity of the in-memory repository. The archive must fit.
        pub markets_max: NonZeroU32,
    }
```

or we have some special syntax in the yaml file, like
```
databento:
    api_key:
        secret: env://DATABENTO_API_KEY

market_info
    location:
        value: env://MKT_INFO_CATALOG
```

or we specify the encryption key and encrypt the secret
```
encription_key: env://CONFIG_ENCRYPTION_KEY

databento:
    api_key:
        stxr_secret: 1234jaklvajlsadfaoiua
```

Maybe even we change the YAML file to something else, I don't care.
I want to have a clear runtime config, that loads some file and can resolve the secrets and env variables.
What are the options?
