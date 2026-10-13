---
create_time: 2026-10-13T10:58:59Z
title: "Catalog of canonical market data feeds: definitions, feed ids, codecs"
summary: "Bring data-feed-core, prototypes/data-feeds-code-generator and the handrolled codecs in data-feed-definitions together into a catalog of canonical market data feeds (like market-info/assets). Missing: canonical feed id (kind id + subject id), shape as a template, all instances generated into one binary file for feed info server clients. First question: how to declare a canonical feed (Databento MBP1) with core types instead of the hardcoded DATABENTO_MBO_FEED static. No decisions yet."
related_sessions:
  - SESS-00Q639F
  - SESS-00PYCE2
  - SESS-00PXT2F
agents:
  - claude-code:d32a6cdc-03e3-4c77-a3ff-e6f6b8ea89c6
  - claude-code:2e25d0d1-a48a-4ccc-8bd4-36673416f558
  - codex:01a134ec-77f7-79d2-b676-9bce6adfb5d7
---

# SESS-00QGNFK: Catalog of canonical market data feeds: definitions, feed ids, codecs

## Goal stated by the user

- Bring three things together:
  - `data-feed-core` (the core types of a data feed),
  - `prototypes/data-feeds-code-generator` (earlier work on feed definitions),
  - `data-feed-definitions/rust/crates/data-feed-definitions` (handrolled feed
    codecs).
- Build a catalog of the market data feeds, similar to how market info is
  handled (`market-info/assets`).

## What is missing, per the user

- No canonical data feed id. The handrolled demo feeds have the idea of a
  data feed kind id and a data feed subject id; together they compose the
  data feed id.
- The shape of a feed should be declared once as a template. Every feed
  instance (template + subject) is then generated into a single binary file
  that the feed info server clients read and distribute.

## Example: Databento MBP1 feed

- Known subject structure: instrument id.
- Known shape: `Mbp1BookUpdate` and `Trade`.
- Known vendor, and a known meaning for each event that comes in.
- The user wants to remove the hardcoded `pub static DATABENTO_MBO_FEED` in
  `data-feed-definitions/rust/crates/data-feed-definitions/src/demo/databento_mbo_feed.rs`
  ("disgusting") and declare the definition with the core types instead.

## Open questions

First question the user wants answered: how do we declare the definition of a
canonical feed such as the Databento MBP1 feed?

It raises these:

1. Where is the shape defined?
2. How is it defined: Rust values or some kind of DSL?
3. How does code get at a definition, or does code always rely on the data
   feed info being passed in a config?
4. How is a feed definition linked to its codec?
5. How do we tell apart the shape of the data that comes in from the
   semantic trait or view applied to that data?

## Decisions

None yet.

## Third-opinion review requested by the user

The user asked Codex to join the existing agents as a third opinion. Codex joined
this record and reviewed core identity/content, the generator prototype, the
handrolled DBN codec, the living data-feed reference, the accepted repository
layout, and the market-info catalog compiler pattern.

The review is in
`../../.dev-env/data/sessions/sess-00qgnfk/notebooks/feed-catalog-third-opinion.md`.
It contains recommendations and explicit open questions, not user decisions.
Key evidence for the other agents: the demo uses one MBP-1 physical record and
dispatches by action; core digest feed IDs and demo concatenated kind/subject
IDs are currently different schemes. No implementation or knowledge-base edits
were made by this review.
