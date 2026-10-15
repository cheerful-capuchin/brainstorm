---
create_time: 2026-10-15T15:03:07Z
title: "Market Info: Stocks"
summary: "Stocks review handoff: IBKR broker venues, FIGI asset identity, spot markets; complete Linear overview, 3 documents and 14 issues saved beside a dev-env brief. Implementation awaits design review."
related_sessions:
  - SESS-00PXT2F
  - SESS-00Q639F
  - SESS-00QGNFK
agents:
  - codex:01a14015-8b27-7781-b34b-0af564a7965c
  - codex:01a1401b-c721-7562-a9ee-a85b9660e7b5
---

# SESS-00QPCHB: Market Info: Stocks

## User request — 2026-10-15

Source project: https://linear.app/stxr/project/market-info-stocks-cee46b5d6e6c/overview

> create me a session and a notebook entry in the dev env regarding of what's going on here. download the whole overview and place in next to the brief somewhere, so the other agents can read the source text as well

The user requested a local session, a notebook explaining the current project,
and the complete source overview beside the brief so other agents can read it.
No implementation or approval of the imported design was requested.

## Session and source capture

- Reused the empty Market Info: Stocks record already created for this topic,
  joined it with the current Codex chat, and attached it as dev-env session
  `sess-00qpchb` in the Structure workspace.
- Notebook brief:
  `.dev-env/data/sessions/sess-00qpchb/notebooks/00-brief.md`.
- Full overview notebook, beside the brief:
  `.dev-env/data/sessions/sess-00qpchb/notebooks/01-linear-overview.md`.
- Exact description text and the complete API metadata:
  `.dev-env/data/sessions/sess-00qpchb/sources/linear-overview.md` and
  `sources/linear-project.json` under the same session.
- Saved all three linked documents, all 14 complete issue descriptions
  (ENG-2280, ENG-2281 and its 12 subissues), and the empty status-update and
  project-comment lists. A manifest records capture time, URLs and SHA-256
  checksums.
- Overview captured 2026-10-15 15:11:23 UTC (17:11:23 Europe/Paris), with source
  updatedAt 2026-10-15T15:00:33.866Z. Other items have their own source update
  times. This is a snapshot, not a live synchronization.

## Imported context, not new decisions in this conversation

The overview contains decisions D1–D44. Later decisions supersede parts of
the opening brief and earlier research:

- Stock asset identity is share-class FIGI; ticker and IBKR conid are aliases.
- Broker is the venue (D19 replaces listing-exchange venues); IBKR comes first
  (D37), while the model and generators stay broker-generic.
- Stock markets are spot with USD quote (D20). Prices attach to the stock,
  separately from broker execution (D24).
- Initial universe is a reviewed repo file seeded from historical S&P 500
  membership, 2018-05-01 through 2026-10-06, including former members.
- Common shares, ADRs and ETFs are included; REITs map to Common. Preferreds,
  warrants, rights and units are excluded.
- Corporate actions and settlement are deferred. IBKR remains whole-share
  until API fraction support and eligibility are verified.
- Labelled schedules distinguish pre-market, regular, after-hours and
  overnight; optional first/last trading dates gate historical lifetime.
- D44 derives IBKR listing status from per-stock lookup, retirement and future
  first-trading dates.

Linear shows the project In Progress, High priority, led by Negative Nilgiri.
The design is awaiting review. ENG-2281 and all 12 implementation subissues
are Todo with no started/completed timestamps; ENG-2280 is Backlog. The
overview's “Backlog” wording is stale. This capture did not inspect code
branches and does not claim any implementation is complete.

## Open points retained

- Q1: FIGI behavior through corporate changes and reviewed mapping overrides.
- Q7: catalog scale/storage, in light of the smaller initial universe and
  specified file layout.
- Q9: reference rules changing over time; ENG-2280 / ISS-0CHDY and ISS-0BWBN.
- Q10: retain stock_type only if a consumer uses it before production.
- Q11: order-book/trade subject identity, outside market-info and nonblocking.
- Q12: IBKR overnight eligibility, fractional API support and conid lookup;
  credential use must first be agreed.
- The opening overview places a DEC before implementation, while ENG-2293
  and the parent issue put the durable DEC last. The brief flags this
  sequence for review rather than choosing one.
- Older linked documents still say the first broker is unknown or session
  labels are a proposal. Their complete original text is preserved.

## Related context

SESS-00PXT2F supplies the preceding CME market-info work. SESS-00Q639F covers
market-info-server contracts and loading. SESS-00QGNFK covers the market-data
feed catalog. No earlier decision was replaced in this capture.

## Re-entry

Open dev-env session `sess-00qpchb`, notebook `00-brief`, then the adjacent
`01-linear-overview`. Read ENG-2281 and D19–D44, reconcile source
discrepancies and DEC timing, and review unresolved engineering/API checks
before implementation. No Linear fields or knowledge-base records changed.

## Verification

- Confirmed the registered session appears in `dev-env sessions` as
  Market Info: Stocks, with no unreadable session files.
- Verified the exact 54,110-byte overview against the complete API description,
  including all 44 decision headings. SHA-256:
  `a2d375b8d18f1679f4712a94e51a5563f6d7708c602f1d53edde6c14ff4af8b8`.
- Verified 14 complete issue descriptions, three linked documents and the
  manifest checksums. The brief makes source disagreements explicit.
- `dev-env check` passed for both notebooks. The brief's snapshot cell
  succeeded locally and through the running app, reporting 13 Todo issues and
  one Backlog issue. The full-source notebook parsed successfully (no cells).
- Requested the brief in the app through `dev-env app run`; no secrets or
  network calls are used by its local snapshot cell.
