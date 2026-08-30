data-feed-definitions/rust/crates/data-feed-definitions/src/demo.rs
knowledge-base/docs/decisions/records/DEC-0ANEJ-simulation-venue-feed.md

For the demo, I want to hardcode the events and the feeds I'm going to handle.
There should also be serialization from the [data feed ref](entity-core/crates/entity-core/src/entities/data_feed.rs:787) to the topic.
I think the schema of `feeds.{feed_id}.{revision_id}.{encoding_kind}`.
For now, we don't have to create a new feed id per each trading account/instrument.

You have to come up with the feed and revision ids for (just one per feed, don't take subject into account):
- sim venue feed (knowledge-base/docs/decisions/records/DEC-0ANEJ-simulation-venue-feed.md)
- databento mkt data

See [StableDataFeedId](entity-core/crates/entity-core/src/entities/data_feed/identity.rs).

---
## Context
Read
- data-feed-definitions/rust/crates/data-feed-definitions/src/demo.rs
- knowledge-base/docs/decisions/records/DEC-0APF7-data-feed-project-structure.md
- knowledge-base/docs/decisions/records/DEC-0ANEJ-simulation-venue-feed.md

I have the definitions, now I need to build the codecs for the feed. For now, those will be hardcoded,
since we don't have the full machinery built around data feeds and code generation.
This feeds and codecs will be used for the High-Frequency Trading. We want to minimize the unnecessary work as much as possible,
while maintaining the correctness.

The codec for the sim venue feed will live in data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0

I think the right thing do to would be to create the proto file with all the protobuf messages defined.
You can take a look at messaging/msg-schemas/proto/common.proto, messaging/msg-schemas/proto/time.proto, BUT you cannot import them.
The proto schema must be self-contained.
Then, create the build.rs file that will use prost (see ./messaging/rust/build.rs) and generate the protobuf files

The layout is:
- /data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/generated/messages.proto -> the protobuf schema
- /data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/generated/messages.rs -> the prost objects
- /data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/generated/messages.serde.rs -> the prost objects (with serde)
- /data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/messages.rs -> import of the messages + trait implementations form data-feed-definitions
- /data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/codec.rs -> PayloadConsumer + PayloadAdapter + FeedHandler

## Requirements

### Zero-copy processing
I don't want to do memcopy or deserialization for the most of the formats (unless it's absolutely necessary).
We should operate on the original message we received, ideally the raw bytes (Databento, SBE, Flatbuffers)

### No enums
The decoder should not ever return the union of types, this bloats the stack and creates unnecessary branching logic
in the decoder, then the adapter, then the handler

### Each event handler should have it's own trait
For each event, there should be a "Handler" trait generated. We'll then compose them to handle a particular feed content shape.
The reason for generating the separate shapes is that we can have the same message be used in multiple feeds.

### The valid message must be a newtype
"Parse, don't validate". If you want to represent that the message is valid, create a new type that is an output of the parse operation.
Do not use .validate() -> Result<(), Error>.
Use .parse() -> Result<T, Error>.

### No strings on the hot path
You cannot just create/allocate strings in the decoders.
If we want the detailed message reporting, I think there should be macros that assign the field/message a stable numerical value
and we only show the value when displaying the error message, never on the hot path

### There must be an adapter
The adapter is essential part of the decoding.
It does more than just validation, it may enrich or change the initial message shape

## Proposed Codec

### Semantic Traits
data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/messages.rs
we use the newtypes to ensure that the protobuf message includes the types we can parse
and then implement the semantic traits on the valid newtype.
You MUST NOT create a new object and deserialize/copy the properties into it.


### Codec
see: data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/codec.rs
The PayloadConsumer is super simple, it just decodes the bytes into the type and dispatches it to the right adapter.
The adapter then does the converstion to this "valid type" and if all good, it dispatches it to the handler

## Questions
I need some help with the codec. I'm not sure those are the best abstractions.
The traits in data-feed-definitions/rust/crates/data-feed-definitions/src/demo/traits.rs are PoC, so I'm ready to change them.

1. What don't you like about the current solution?
2. What improvements can we make?
3. How do you ensure that the protobuf message we received is correct?
4. How do you make the adapter abstraction to handle all the feed messages?

do NOT edit the files, propose solutions only. Prefer writing Rust code, rather than English prose.
Your output per question is 500 words max (excluding the code)


---

I want you to add the feed usage to the event gw event-gw/crates/event-gw/src/host.rs
For the demo purposes, we don't have the proper feed resolution infrastructure. Therefore, I just hardcoded the topic with the sim gw events
data-feed-definitions/rust/crates/data-feed-definitions/src/demo.rs

Basically, if subject eq SIM_VENUE_FEED topic in EventGwHost::on_nats_msg, we decode the message and go through the whole pipeline.
How would you integrate the codec (consumer part) into the event gw component?

For now, the venue gw messages should be simply logged using dbg!()

What is the structure, how do you create the handler and match it with event-gw/crates/event-gw/src/logic module, etc?

---
## Context
Read
- data-feed-definitions/rust/crates/data-feed-definitions/src/demo.rs
- knowledge-base/docs/decisions/records/DEC-0APF7-data-feed-project-structure.md
- knowledge-base/docs/decisions/records/DEC-0ANEJ-simulation-venue-feed.md

I have the definitions, now I need to build the codecs for the feed. For now, those will be hardcoded,
since we don't have the full machinery built around data feeds and code generation.

The codec for the sim venue feed will live in data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0

I think the right thing do to would be to create the proto file with all the protobuf messages defined.
You can take a look at messaging/msg-schemas/proto/common.proto, messaging/msg-schemas/proto/time.proto, BUT you cannot import them.
The proto schema must be self-contained.
Then, create the build.rs file that will use prost (see ./messaging/rust/build.rs) and generate the protobuf files

The layout is:
- /data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/generated/messages.proto -> the protobuf schema
- /data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/generated/messages.rs -> the prost objects
- /data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/generated/messages.serde.rs -> the prost objects (with serde)
- /data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/messages.rs -> import of the messages + trait implementations form data-feed-definitions
- /data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/codec.rs -> PayloadConsumer + PayloadAdapter + FeedHandler

## Task
ONLY generate the messages in messages.proto. Setup the build.rs to output the rust structs into src/generated/messages.rs.
do NOT touch the codec.rs file




