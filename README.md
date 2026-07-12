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
- **CSV** import with configurable column mapping and saved profiles.
- **QIF** (Quicken Interchange Format) import.
- **OFX / QFX** import (OFX v1 SGML and v2 XML; bank, card, and investment statements).
- A shared **import matcher** for duplicate detection and destination-account assignment.

**Planning & guidance** (Microsoft Money–inspired — layered on the accounting core; later releases)
- Bill reminders + financial calendar; cash-flow forecasting with what-if scenarios.
- Budgets with rollover/envelope semantics; proactive alerts (bills due, low balance, over budget) via notifications and widgets.
- Portfolio watch lists, asset allocation, and rate of return.
- Debt Reduction Planner and long-range Lifetime Planner; a home dashboard with net-worth trend.
- See [docs/enhancements-msmoney.md](docs/enhancements-msmoney.md).

**Automation & organization** (Firefly III–inspired)
- A **rules engine** (trigger/action groups) to auto-categorize, tag, and organize transactions — on import or applied to history.
- **Tags** (cross-cutting labels), **savings goals** (piggy banks), and an **operator search language** with saved searches.
- Bill matching, auto-budgets, and a later path to **modern bank sync** (SimpleFIN / GoCardless) + CAMT.053 import.
- See [docs/enhancements-firefly.md](docs/enhancements-firefly.md).

**Connectivity & wellness** (Frollo-inspired — optional, consented, local-first)
- Australian **Open Banking (CDR)** bank sync via an accredited intermediary (later; alongside SimpleFIN/GoCardless).
- Default category taxonomy with heuristic auto-categorisation; savings challenges; an explainable **financial wellbeing score**; a shareable **financial summary ("passport")** PDF.
- See [docs/enhancements-frollo.md](docs/enhancements-frollo.md).

### Out of scope (initially)

- The GnuCash on-disk backends (its XML store, and SQLite/MySQL/PostgreSQL) — FinvestLens has its own `.finvestlens` SQLite document; GnuCash XML is an import/export interchange format only.
- Business features such as full invoicing, accounts payable/receivable workflows, payroll, and tax tables (candidates for later releases).
- **Online bank sync** (later releases) — planned around modern aggregation APIs (**SimpleFIN / GoCardless**) rather than legacy OFX DirectConnect/AqBanking — plus MT940/MT942 and CAMT.053 statement import. *(Note: CSV/QIF/OFX **file** import is in scope — see above; only live online connections are deferred.)*
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
| Import/Export | GnuCash XML reader & writer (interchange); native CSV/QIF/OFX-QFX importers + import matcher |
| Sync (planned) | File-level (iCloud Documents / Files) with conflict resolution |

The core engine is kept free of UI and persistence dependencies so it can be unit-tested in isolation and reused across platforms. See [docs/prd.md](docs/prd.md), [docs/architecture.md](docs/architecture.md), [docs/porting.md](docs/porting.md), and the [implementation plan](docs/plan.md).

## Roadmap

1. **Foundation** — core model types, `Decimal`-based money, double-entry invariant, unit tests.
2. **Document** — native `.finvestlens` SQLite store (GRDB); open/save; NAS locking + atomic write-back.
3. **Import** — read GnuCash XML into the native store.
4. **UI** — chart of accounts and transaction register.
5. **Export** — write GnuCash XML back out; verify round-trip fidelity.
6. **Reports & reconciliation.**
7. **Scheduled transactions.**
8. **File-level sync.**

## Platform requirements

- macOS, iPadOS, iOS — minimum versions to be finalized (target current − 1 major).
- Built with Swift and SwiftUI in Xcode.

## Licensing

FinvestLens is free software, distributed under the **[GNU General Public License v3.0](LICENSE)** — the same copyleft family used by [GnuCash](https://www.gnucash.org) (which is licensed GPLv2-or-later). Using the GPL keeps FinvestLens license-compatible with GnuCash, so its concepts — and, where useful, its source — can be drawn on directly.

The GnuCash XML format is treated as an interchange specification. This is not an official GnuCash product and is not affiliated with or endorsed by the GnuCash project.

## Status

Early development. The Xcode project is scaffolded; the core engine and import/export are being built out per the roadmap above.
