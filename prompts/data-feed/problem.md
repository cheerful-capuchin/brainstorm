## Problem statement

### What & Where
- I want to have a centralized catalog that describes __what__ kind of data we're able to send and receive
- I want to have a centralized catalog that describes __where__ can we receive what kind of data

For example, OHLCV bar is a common shape that we use to get the prices. However, different providers
provide different units (seconds, minutes, hours, days) and different sizes (1, 3, 5, 10, 15, 30) etc.

I want to be able to answer 2 questions:
- is it possible for me to fetch the OHLCV 1-minute bars for ESZ2026 E-MINI S&P 500 FUTURES?
- where do I fetch that data?

Is it 2 questions or 1 question -> where can I find the data for {}? And the question whether we support depends on found vs not found?

### Views
I want to be able to declare the shape of the data that I'm working using
our domain types as well as certain validation rules.
Based on that contract, I want to be able to generate the types in rust, ts, python, and, possibly, other languages.

### Events
View just describes the data. Event describes the meaning and behaviour.
Coming back to the OHLCV question, the view for the different units and different sizes is the same
```
instrument
event_time
open
high
low
close
volume
```
However, the meaning behind each event is different

### Protocol
I want to be able to describe the protocol of the communication between the client and the server.
I want to generate the types and the encoders/decoders for all the supported languages

### Dynamism
I want to support the dynamic registration of the custom protocols and data feeds, so our users can build their
pipelines in the say they want without having us to build anything for them except the primitives.

### Exising encoding formats
I don't want to describe all the possible wire contracts and transformation to our data feeds/protocols in a declarative manner.
There are too many different formats and rules and the best way to express logic is in code.
Therefore, all the decoders and adapters will be in Rust.
However, what I don't want is to duplicate that decoding and adapter logic in multiple languages.
I want to have a single "platform" language that handles all the I/O and decoding
and then calls into the core, which could still be in rust or could be something like typescript or python.
This is following the idea of the Roc programming language. They optimize it for the domain code vs platform code.
https://www.roc-lang.org/

