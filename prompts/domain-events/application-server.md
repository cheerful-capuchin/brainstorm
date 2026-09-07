## Requirements
- no file edits
- max 500 words per reply (excluding code)
- more code, less english prose

## Context
The current implementation of the application server mixes the concepts of the domain events and direct mutations to the database.
This removes the concept of a single source of truth and causes divergence. Additionally, all the operations are concurrent, and there is
no single order for the events. Therefore, I cannot reliably tell "event A happened after event B". We cannot rely on timestamps there.

Let's take a look at the [TradingAccountService](structure-web/packages/api/src/trading-accounts/trading-accounts-service.ts), specifically
the [TradingAccountService::create](trading-accounts-service.ts:137) function.
It does many things in order to create a trading account. Then, I have to wrap everything in a transaction to get the current "fresh" data,
upsert the account, attach the user, and only then emit the feed event that doesn't event include all the necessary properties of that account.
Moreover, this feed event is not stored in the same database. Actually, it's not stored anywhere at all.
To test this, I have to pass a fake argus instance that collects the events into a queue, but again, those events omit/miss data.

I had some reading to how the Foundation DB and the Tigerbeetle databases are working.
It seems that the common theme for them is to have a stream of transactions that are all ordered and deterministically executed against the executor.
I imagine we could have the same, where we create the command that is then executed and produces a multiple events that are then executed,
stored as the provenance, published to the event bus.

Despite having the conceptual understanding, I'm lacking details.

## Questions

### 1. How is the state loaded?
Details: the application server tries to store the minimum amounts of data for it to operate.
That means, however, that it needs to go to the database every time there is something happening to populate the state.
How do we load the state in case of the above-mentioned architecture?

### 2. How do we interact with the external APIs?
Details: in the example of the trading account, when one is about to be created, we check the external venues to verify that the account
exists. Does this kind of validation happen before we enter the sequential state machine?

### 3. How are the domain events persisted and how do we derive the latest views?

### 4. How does it work with horizontal scaling?
Details: when I have a single ordered stream, this becomes problematic the moment there is more than one instance


---
## Requirements
- use plain technical English

## Context
I want to create a new knowledge base issue "application server domain events", where I'll outline the issues with our current implementation.

The current implementation of the application server mixes the concepts of the domain events and direct mutations to the database.
This removes the concept of a single source of truth and causes divergence. Additionally, all the operations are concurrent, and there is
no single order for the events. Therefore, I cannot reliably tell "event A happened after event B". We cannot rely on timestamps there.

Let's take a look at the [TradingAccountService](structure-web/packages/api/src/trading-accounts/trading-accounts-service.ts), specifically
the [TradingAccountService::create](trading-accounts-service.ts:137) function.
It does many things in order to create a trading account. Then, I have to wrap everything in a transaction to get the current "fresh" data,
upsert the account, attach the user, and only then emit the feed event that doesn't event include all the necessary properties of that account.
Moreover, this feed event is not stored in the same database. Actually, it's not stored anywhere at all.
To test this, I have to pass a fake argus instance that collects the events into a queue, but again, those events omit/miss data.

I had some reading to how the Foundation DB and the Tigerbeetle databases are working.
It seems that the common theme for them is to have a stream of transactions that are all ordered and deterministically executed against the executor.
I imagine we could have the same, where we create the command that is then executed and produces a multiple events that are then executed,
stored as the provenance, published to the event bus.

Despite having the conceptual understanding, I'm lacking details and it's not time to solve this problem for the demo.

## Open Questions

### 1. How is the state loaded?
Details: the application server tries to store the minimum amounts of data for it to operate.
That means, however, that it needs to go to the database every time there is something happening to populate the state.
How do we load the state in case of the above-mentioned architecture?

### 2. How do we interact with the external APIs?
Details: in the example of the trading account, when one is about to be created, we check the external venues to verify that the account
exists. Does this kind of validation happen before we enter the sequential state machine?

### 3. How are the domain events persisted and how do we derive the latest views?

### 4. How does it work with horizontal scaling?
Details: when I have a single ordered stream, this becomes problematic the moment there is more than one instance



## Task
Create the knowledge base issue. You have to keep the open questions. Stage the file to git.
I want only syntax and grammar fixes. Maybe a bit of rewording, but don't do your own interpretations.
