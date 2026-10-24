ensure there is a session file created (decision-log skill)

## Context
Recently, we had a bunch issues with monitoring and observability.
I think infra is still not pushed.
We had services in crash loop, databases down, printing errors and warnings, having doom loops and we knew absolutely nothing about it.

I want to have a proper monitoring feature for our engine applications.
We already have something half-backed in logger2.
Ideally, the monitoring/rust/crates has a crate that handles the sink for logging, alerting,
sending the messages, panic capturing, call stack unwinding for panics, etc.

So, in the beginning of the application, we init the monitoring and all the logs, traces, telemetry, metrics go through there,
so we can have full observability into what's going on.

Something similar to what sentry does
```
fn main() {
    let _guard = sentry::init(
        std::env::var("SENTRY_DSN")
            .expect("SENTRY_DSN must be set")
    );

    // This error is explicitly reported.
    let result = "invalid".parse::<u32>();

    if let Err(error) = result {
        sentry::capture_error(&error);
    }

    // This panic is captured automatically.
    // panic!("Something went wrong!");
}
```

However, we need it for HFT.
I assume we can create a separate NATS instance just for all the monitoring to never interfere with trading.
Then, by leveraging the flatbuffers I think we can pack multiple events into a single message and then on the backend,
similarly to cloudflare https://blog.cloudflare.com/one-observability-platform/ we do the sorting, dispatching, etc.

I want to be able to see the states/metrics and logs of the engine application.

I already had an idea of subject vs source in messaging/msg-schemas/proto/structure/event_log.proto.

However, with source the issue is that the keys are free strings and it's easy to make mistakes in naming.
"strategy_revision" vs "revision" vs "strat_revision" and so on.

so, I'm not sure what to do there.

The event-gw/README.md can handle the storage and the notify-gw from monitoring/README.md will handle the alerting.

## Panics
we need to set up a global panic hook to add the panic as a message to the monitoring buffer and then immediately flush.
We can also handle the stack unwinding, but only with the addresses. We'll map them to the debug symbols in post-processing.
I assume we'll have something like a build id, and we'll store the binary with debug info in the bucket somewhere or in the docker
image itself. We can build the image with one stipped prod binary and one with the debug symbols and then, I think, access it through
the docker fs.

## Sink
I think NATS is a good option for us right now.
For something durable we can use jetstream, but for most of the things, I guess a regular NATS is a good enough option.
The channel must be bounded and the messages must be sent via try_send
if we have a slow consumer, we should not block the main thread from emitting logs

## Metrics
I think this should be an optional config setting that on timer emits the state of the things we care about.
Maybe we'll even accept some kind of collector that will give us the metrics the user of the monitoring worker cares about.


## Task
What are your thoughts and suggestions. How can we implement it?


## Accepted suggestions

### Each event gets a numeric id at compile time
Because we know all the logged values at compile-time,
we can replace the plain strings, with numerical identifiers
and as long as we keep the build id and revision,
we can always lookup the id in the generated table of strings.
Therefore, the logs collector can then map the ids to string literals.
