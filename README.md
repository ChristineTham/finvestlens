# FinvestLens

A native Apple double-entry accounting application for macOS, iPadOS, and iOS — a Swift reimplementation of the [GnuCash](https://www.gnucash.org) accounting engine, built to feel completely at home on Apple platforms.

FinvestLens ports GnuCash's proven core accounting model into modern Swift, presenting it through **SwiftUI** and saving to its **own native document format** (a single SQLite `.finvestlens` file), while remaining interoperable with GnuCash through XML import and export. It is **native-first**: it opens and saves its own file — usable on local disk, iCloud, or a network share (NAS) — rather than adopting GnuCash's on-disk format.

---

## Purpose

GnuCash is a mature, trusted, free-software personal and small-business accounting package built on rigorous double-entry bookkeeping. Its desktop UI, however, is built on GTK and does not integrate with the Apple ecosystem — no native look and feel, no iPad or iPhone version, no iCloud sync, no Shortcuts, no Apple platform conventions.

FinvestLens exists to give users of the Apple ecosystem a first-class, native accounting app that:

- Preserves the **correctness and rigour** of GnuCash's double-entry engine.
- Feels **genuinely Apple-native** — SwiftUI, a native document format, platform navigation patterns, Dark Mode, Dynamic Type, VoiceOver.
- Runs on **macOS, iPadOS, and iOS** from a single shared codebase.
- Remains **interoperable** with GnuCash by reading and writing the standard GnuCash XML file format, so users are never locked in and can move between the two applications.

FinvestLens is not a fork of GnuCash. It is a clean, idiomatic Swift reimplementation of GnuCash's *concepts and data model*, designed for the Apple platform from the ground up.

## Scope

### In scope (v1)

**Core accounting engine**
- Double-entry bookkeeping with balanced transactions and splits.
- The GnuCash account model: hierarchical chart of accounts with account types (Asset, Bank, Cash, Credit, Liability, Equity, Income, Expense, Receivable, Payable, Stock, Mutual Fund, Trading, etc.).
- Transactions composed of two or more splits that must balance to zero.
- **Native `Decimal` money** (no binary floating-point error), rounded to each commodity's fraction. Exact bit-for-bit parity with GnuCash's arithmetic is a non-goal; small rounding differences are acceptable.
- Commodities and currencies, including multi-currency accounts and price/exchange-rate handling.
- A price database for commodity and currency valuations.
- **Online price quotes** via pluggable providers: a keyless *yfinance-like* Yahoo source out of the box, plus keyed services (**EODHD** — including historical prices for **delisted** securities — Alpha Vantage, Finnhub) with API keys stored in the Keychain. Supports historical backfill.

**Native document & platform integration**
- A native **SQLite document format** (`.finvestlens`, via GRDB) that the app opens and saves — the canonical store.
- **Network-share (NAS) friendly**: application-level file locking (single-writer, with heartbeat and stale-lock detection) and safe atomic write-back.
- SwiftUI-based UI across all three platforms with adaptive layouts.
- Planned iCloud/Files-based sync (file-level, with conflict resolution — see roadmap).

**Interoperability**
- **Import** of GnuCash XML files (uncompressed and gzip-compressed).
- **Export** to GnuCash XML, round-trip compatible with GnuCash desktop.
- Faithful mapping between the GnuCash data model and FinvestLens's native model.

**Everyday accounting features**
- Register/ledger view for entering and editing transactions.
- Chart of accounts with running balances.
- Basic reconciliation.
- Scheduled/recurring transactions.
- Core reports (account balances, income/expense, net worth).

**Bank/financial file import** (native, reimplemented in Swift — not GnuCash's importers)
- **CSV** import with configurable column mapping (saved mapping profiles are planned — see [deferred.md](docs/deferred.md)).
- **QIF** (Quicken Interchange Format) import.
- **OFX / QFX** import (OFX v1 SGML and v2 XML; bank, card, and investment statements).
- **MT940 / MT942** (SWIFT) and **CAMT.053** (ISO 20022) statement import, with format auto-detection (extension + content sniffing).
- A shared **import matcher** for duplicate detection (FITID `online_id` + amount/date with one-to-one claiming), destination-account assignment from payee history, and **cross-account transfer completion** (the second statement of a transfer re-points the first statement's wash leg instead of duplicating it).

**Planning & guidance** (Microsoft Money–inspired — layered on the accounting core; later releases)
- Bill reminders + financial calendar; cash-flow forecasting with what-if scenarios.
- Budgets with rollover/envelope semantics; proactive alerts (bills due, low balance, over budget) via notifications and widgets.
- Portfolio watch lists, asset allocation, and rate of return.
- Debt Reduction Planner and long-range Lifetime Planner; a home dashboard with net-worth trend.
- See [docs/enhancements-msmoney.md](docs/enhancements-msmoney.md).

**Automation & organization** (Firefly III–inspired)
- A **rules engine** (trigger/action groups) to auto-categorize, tag, and organize transactions — on import or applied to history.
- **Tags** (cross-cutting labels), **savings goals** (piggy banks), and an **operator search language** with saved searches.
- Bill matching and auto-budgets. *(CAMT.053 import shipped with P8; online bank sync skipped by decision — see deferred.md.)*
- See [docs/enhancements-firefly.md](docs/enhancements-firefly.md).

**Connectivity & wellness** (Frollo-inspired — optional, consented, local-first)
- Australian **Open Banking (CDR)** bank sync via an accredited intermediary (later; alongside SimpleFIN/GoCardless).
- Default category taxonomy with heuristic auto-categorisation; savings challenges; an explainable **financial wellbeing score**; a shareable **financial summary ("passport")** PDF.
- See [docs/enhancements-frollo.md](docs/enhancements-frollo.md).

### Out of scope (initially)

- The GnuCash on-disk backends (its XML store, and SQLite/MySQL/PostgreSQL) — FinvestLens has its own `.finvestlens` SQLite document; GnuCash XML is an import/export interchange format only.
- Business features such as full invoicing, accounts payable/receivable workflows, payroll, and tax tables (candidates for later releases).
- **Online bank sync** — skipped by decision (24 Jul 2026): cloud-mediated connectors sit poorly with the local-first stance; see [deferred.md](docs/deferred.md) §5. *(Note: statement **file** import — CSV/QIF/OFX/MT940/CAMT.053 — is fully in scope and delivered; only live online connections are out.)*
- **REST API / webhooks** (Firefly-style server features) — out of scope for a native document app; automation is served by Shortcuts / App Intents instead.
- The GnuCash Scheme/Guile reporting and scripting system — reports are reimplemented natively.
- Stock/investment lot tracking and advanced capital-gains reporting (later release).

### Non-goals

- Bit-for-bit reproduction of GnuCash's arithmetic, or binary compatibility with GnuCash's own on-disk stores.
- Reproducing GnuCash's exact UI or workflow — FinvestLens follows Apple Human Interface Guidelines instead.

## Architecture (intended)

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI (macOS / iPadOS / iOS) |
| Document / store | Native `.finvestlens` SQLite file via **GRDB**; in-memory model is the source of truth |
| Shared-storage safety | App-level file locking + heartbeat; local working copy; explicit (Save/autosave) atomic write-back; discardable sessions (NAS-safe) |
| Core engine | Pure-Swift accounting model (accounts, transactions, splits, commodities, prices) |
| Numbers | Native `Decimal` money (rounded per commodity) |
| Derived state | Everything shown is derived from the in-memory `Book`; expensive derivations (price lookups, per-account balances, journal rows) are indexed or cached and invalidated on the same signal that drives the redraw |
| Undo | Each edit captures only what it is about to change, before changing it — no whole-book snapshots |
| Import/Export | GnuCash XML reader & writer (interchange); native CSV/QIF/OFX-QFX/MT940/CAMT.053 importers + import matcher |
| Sync (planned) | File-level (iCloud Documents / Files) with conflict resolution |

The core engine is kept free of UI and persistence dependencies so it can be unit-tested in isolation and reused across platforms. See [docs/prd.md](docs/prd.md), [docs/architecture.md](docs/architecture.md), [docs/porting.md](docs/porting.md), and the [implementation plan](docs/plan.md).

## Roadmap

Phased delivery (full detail in [docs/plan.md](docs/plan.md)):

- ✅ **P0 Foundation** — core model, `Decimal` money, double-entry invariant, unit tests.
- ✅ **P1 Document + import** — native `.finvestlens` SQLite store (GRDB); open/save; NAS locking + atomic write-back; GnuCash XML import.
- ✅ **P2 Core UX** — chart of accounts and transaction register.
- ✅ **P3 Export + round-trip** — write GnuCash XML back out; verified lossless round-trip.
- ✅ **P4 Everyday finance** — reconcile, scheduled transactions, budgets, reports, bank import (CSV/QIF/OFX), rules, search.
- ✅ **P5 Investments** — multi-currency, price quotes, lots/cost-basis, trading accounts.
- ✅ **P6 Sync, dashboard, alerts & polish** — file-level sync machinery, home dashboard, alerts, book lock, usability + HIG passes. *(Plus post-1.0: Apple Intelligence — on-device PDF import, categorisation, forecasts.)*
- ✅ **P7 Business** — customers/vendors/employees, invoices/bills, payments, aging, tax tables, business XML round-trip.
- ✅ **Usability & performance redesign (Jul 2026)** — four audit passes (usability, functionality, performance, session/resilience) executed as four phases: one expandable register, plain language, a viewport-fitting dashboard, reconcile reimagined around auto-clear, one-click price updates, a single status/progress overlay, session restoration, memoised async reports, and an EOFY Financial Year Pack.
- ✅ **Report-quality redesign (Jul 2026)** — statements at annual-report presentation standard (hierarchical face-and-notes built from the user's own chart of accounts, ASC 274 liquidity/maturity ordering, materiality folding, accounting typography with comparatives — including the Trial Balance), plus two presentation decks: a CFO-style **Financial Review** and a factsheet-style **Investment Review**, each with charts, callouts, and on-device insights that a deterministic validator keeps grounded in the slide's own figures. Plan and research: [report-redesign.md](docs/report-redesign.md).
- ✅ **P8 Extended import (Jul 2026)** — SWIFT **MT940/MT942** and ISO 20022 **CAMT.053** statement import through the Import Matcher, with format auto-detection (extension + content sniffing); plus an import-matcher hardening pass validated on real bank exports — cross-account **transfer completion**, FITID-mismatch veto, one-to-one duplicate claiming, credit-card funding inference, and an Imbalance fallback feeding the Uncategorised sweep. *(Online bank sync skipped by decision — local-first; see deferred.md.)*
- ⬜ **P9 Planning & insights** — debt & lifetime planners, tax estimator/TXF, savings goals, wellbeing score.

## Platform requirements

- macOS, iPadOS, iOS — minimum versions to be finalized (target current − 1 major).
- Built with Swift and SwiftUI in Xcode.

## Licensing

FinvestLens is free software, distributed under the **[GNU General Public License v3.0](LICENSE)** — the same copyleft family used by [GnuCash](https://www.gnucash.org) (which is licensed GPLv2-or-later). Using the GPL keeps FinvestLens license-compatible with GnuCash, so its concepts — and, where useful, its source — can be drawn on directly.

The GnuCash XML format is treated as an interchange specification. This is not an official GnuCash product and is not affiliated with or endorsed by the GnuCash project.

## Status

**Phases P0–P7 are complete** — the core engine, native document + NAS locking, GnuCash import/export, core UX, everyday finance, investments/multi-currency/quotes, sync/dashboard/alerts, Apple Intelligence, and small-business features — **plus two July 2026 redesigns**: the usability & performance pass (persona-driven audits → a phased rework of the register, dashboard, reconcile, prices, and feedback surfaces; [usability-review.md](docs/usability-review.md), [performance-review.md](docs/performance-review.md)) and the report-quality pass (annual-report statements with face-and-notes presentation, and the Financial/Investment Review decks; [report-redesign.md](docs/report-redesign.md)). **P8** (extended import / bank sync) and **P9** (planning & insights) remain. What has been built is recorded in [implemented.md](docs/implemented.md); everything still open is in [deferred.md](docs/deferred.md).

Exercised against a real GnuCash book — 46,553 transactions, 559 accounts, 102,706 prices, multi-currency — imported and compared side by side with GnuCash 5.16, which it matches to the cent (net worth, every account subtree, register running balances, the balance sheet, and the investment reports). Interoperability is round-trip verified: a re-export is byte-identical, and GnuCash reads FinvestLens's exported file back.

Performance is measured against that book, not a synthetic one. Opening it takes ~6.3s and a register edit ~0.26s (an account edit 0.067s), down from ~26s and several seconds; the general ledger scrolls all 46k transactions with jumps to either end instant. The 2026 redesign added a further layer: the register status strip is snapshotted in the same pass that builds the rows (was three full-book scans per render), QuickFill reads a per-revision cache (was a 46k-transaction sort per keystroke), price and settings edits snapshot only what they touch for undo (was a whole-book XML export), heavy reports are memoised per (parameters, book revision) and build behind a placeholder, and an `os_signpost` harness watches every hot path. The design behind those numbers — and what is still deliberately slow — is [architecture.md §10](docs/architecture.md#10-derived-state-and-performance).

Not yet released. iOS can open, create, and edit books but not import or export (a deliberate non-goal — see the PRD). CI builds and tests the core packages (plus an SPDX-header gate) on every push; the app + Intelligence job rides along until a hosted macOS 26 runner exists.
