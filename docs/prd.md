# FinvestLens — Product Requirements Document

| | |
|---|---|
| **Product** | FinvestLens — native Apple double-entry accounting |
| **Platforms** | macOS, iPadOS, iOS |
| **Document status** | Requirements baseline v1.0 |
| **Author** | Christine Tham |
| **License** | GNU GPL v3.0 |

> This PRD states **intended requirements**, not build status. What has been implemented is recorded in the [plan](plan.md) and [implemented.md](implemented.md); what remains open is in [deferred.md](deferred.md).

---

## 1. Introduction

FinvestLens is a native Swift application for personal and small-business accounting on Apple platforms. It reimplements the core accounting engine of [GnuCash](https://www.gnucash.org) — a mature, free double-entry bookkeeping package — using modern Apple technologies (**SwiftUI** for the interface, a native **SQLite document format** for storage) while remaining interoperable with GnuCash through XML import/export. It is **native-first**: it opens and saves its own document format rather than adopting GnuCash's on-disk format.

This PRD defines the product's purpose, scope, target users, and detailed functional and non-functional requirements. It is grounded in the GnuCash [Tutorial and Concepts Guide](https://www.gnucash.org/docs/v5/C/gnucash-guide/) and [Help Manual](https://www.gnucash.org/docs/), which describe the domain model and feature set FinvestLens targets.

### 1.1 Purpose

Give Apple-ecosystem users a first-class, native accounting application that preserves the rigour of GnuCash's double-entry engine while feeling genuinely at home on Mac, iPad, and iPhone, and never locks users in — data moves freely to and from GnuCash. Beyond parity, FinvestLens draws on three other tools for what GnuCash lacks: the **consumer-grade planning and guidance** that made Microsoft Money approachable (forecasting, budgeting with rollover, bill reminders, proactive alerts, long-range planning — [§5.16](#516-planning-forecasting--insights-microsoft-moneyinspired), [study](enhancements-msmoney.md)); the **automation and organization** of Firefly III (a rules engine, tags, savings goals, an operator search language, modern bank sync — [§5.17](#517-automation-tags--goals-firefly-iiiinspired), [study](enhancements-firefly.md)); and the **connected-data, engagement, and financial-wellness** ideas of Frollo, adapted to Australia's Open Banking / CDR and to a local-first stance ([study](enhancements-frollo.md)). The positioning is a four-way synthesis: **GnuCash's rigor + Money's planning + Firefly's automation + Frollo's connectivity & wellness**, natively on Apple platforms. All of it sits on the accounting core as read-models, guided workflows, or optional/consented connectors — never weakening double-entry integrity, and never compromising the app's offline, private, local-first core.

### 1.2 Background: the GnuCash domain model

GnuCash is built on classical double-entry bookkeeping. The essential concepts FinvestLens must reproduce:

- **Book** — the top-level container for a set of accounts and their data (a "file").
- **Account** — a named bucket with a *type* (Asset, Bank, Cash, Credit Card, Liability, Equity, Income, Expense, Receivable, Payable, Stock, Mutual Fund, Trading). Accounts form a **hierarchy** (tree).
- **Transaction** — a dated economic event, composed of two or more **splits** that must sum to zero (the double-entry invariant).
- **Split** — one leg of a transaction: an amount posted to a specific account, with a value (in the transaction's currency) and a quantity (in the account's commodity). Carries a reconciliation state (n/c/y — not/cleared/reconciled) and optional memo/action.
- **Commodity** — a currency or a security (stock, fund). Accounts are denominated in a commodity.
- **Price** — a commodity's value in another commodity at a point in time (the price/quote database).
- **Lot** — a grouping of splits used to track cost basis for capital-gains calculation.
- **Scheduled Transaction** — a template plus a recurrence rule that generates future transactions.
- **Budget** — planned amounts per account per period.
- **Business objects** — customers, vendors, employees, invoices, bills, jobs, billing terms, tax tables, entries.

### 1.3 Definitions

See the [Glossary](#15-glossary) (§15).

---

## 2. Goals and non-goals

### 2.1 Goals

- **G1** — Implement GnuCash's double-entry engine with native Swift **`Decimal`** money (no binary-float error); exact `gnc_numeric` parity is a non-goal.
- **G2** — Be a **native-first document app**: open/save FinvestLens's own SQLite document format, usable on local, iCloud, and network (NAS) storage.
- **G3** — Round-trip GnuCash XML files: import an existing GnuCash file and export one GnuCash can reopen without data loss for supported object types.
- **G4** — Deliver everyday personal-finance workflows (accounts, register, reconciliation, scheduled transactions, reports) in v1.
- **G5** — Provide a shared codebase across macOS, iPadOS, and iOS with platform-adaptive UI.

### 2.2 Non-goals

- **NG1** — Binary/on-disk compatibility with GnuCash's own backends (its XML file, or its SQLite/MySQL/PostgreSQL stores). GnuCash XML is an import/export interchange format; FinvestLens's native store is its own `.finvestlens` SQLite document.
- **NG2** — Reproducing GnuCash's exact GTK UI or workflows. FinvestLens follows the Apple Human Interface Guidelines.
- **NG3** — Reimplementing the GnuCash Scheme/Guile scripting or Python bindings.
- **NG4** — Providing financial or investment advice. FinvestLens is a record-keeping tool, not an advisor.
- **NG5** — Executing trades, payments, or fund transfers. FinvestLens records transactions; it does not move money.

---

## 3. Target users and personas

| Persona | Description | Primary needs |
|---|---|---|
| **Migrating GnuCash user** | Existing GnuCash user on Windows/Linux/older Mac wanting a native Apple app | Lossless import/export, familiar model, feature parity for their workflow |
| **Personal-finance keeper** | Individual tracking bank accounts, credit cards, income/expenses, budgets | Fast transaction entry, reconciliation, clear reports, iCloud sync across devices |
| **Investor** | Tracks stocks, funds, and multi-currency holdings | Commodity/price tracking, quote retrieval, capital-gains reporting |
| **Small-business owner** | Sole trader / small business needing invoicing and A/R–A/P | Customers, vendors, invoices, bills, tax tables (later phase) |

---

## 4. Scope and release phases

FinvestLens is delivered in phases. Requirement priorities use **MoSCoW** (Must / Should / Could / Won't-for-now). Each phase is releasable.

| Phase | Theme | Highlights |
|---|---|---|
| **P0 — Foundation** | Core engine | Data model, `Decimal`-based `Money`, double-entry invariant, unit tests |
| **P1 — Document & Import** | Native SQLite document + read GnuCash | GRDB schema, `.finvestlens` open/save, NAS locking, GnuCash XML import |
| **P2 — Core UX** | Usable app | Chart of accounts, transaction register, editing |
| **P3 — Export & round-trip** | Interoperability | GnuCash XML export, round-trip fidelity tests |
| **P4 — Everyday finance & bank import** | Depth | Reconciliation, scheduled transactions, basic reports; **native CSV/QIF/OFX-QFX import + Import Matcher**, CSV export |
| **P5 — Investments & multi-currency** | Advanced | Commodities, price DB, quotes, capital gains |
| **P6 — Sync & polish** | Ecosystem | File-level sync, Shortcuts, widgets, accessibility pass |
| **P7 — Business features** | SMB | Customers/vendors, invoices/bills, tax tables, A/R–A/P |
| **P8 — Extended import/export** | Interop breadth | MT940/MT942 + CAMT.053 import; online bank sync; PDF export |
| **P9 — Planning & insights** | Money-inspired | Debt Reduction Planner, Lifetime Planner, tax estimator, insights/comparison reports |

Planning features that layer onto earlier phases (bill reminders, cash-flow forecast, alerts, budgets, payee rules, portfolio, dashboard, onboarding) are scheduled within P4–P7 — see [§5.16](#516-planning-forecasting--insights-microsoft-moneyinspired) and the [enhancement study](enhancements-msmoney.md). An optional on-device **Apple Intelligence** layer ([§5.18](#518-on-device-intelligence-apple-intelligence), FR-AI-01…08) adds PDF statement/invoice/dividend import, auto-categorisation, and budget/forecast narration over the same engine — see [Architecture §11](architecture.md#11-apple-intelligence-integration-intelligence-package).

---

## 5. Functional requirements

Requirement IDs are stable references. **Pri** = priority; **Phase** = target phase.

### 5.1 Core accounting engine

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-ENG-01 | Represent monetary amounts with Swift-native **`Foundation.Decimal`** (wrapped in a `Money` type with its commodity), avoiding binary floating-point error. Bit-exact parity with GnuCash's `gnc_numeric` is **not** required; small rounding differences are acceptable. | Must | P0 |
| FR-ENG-02 | Model **Account** with: name, type, code, description, notes, parent, commodity, commodity scaling (SCU), hidden/placeholder flags, and a stable GUID. | Must | P0 |
| FR-ENG-03 | Support the full set of GnuCash **account types**: Asset, Bank, Cash, Credit, Liability, Equity, Income, Expense, Receivable, Payable, Stock, Mutual Fund, Trading, Root. | Must | P0 |
| FR-ENG-04 | Model **Transaction** with date posted, date entered, description, number, notes, currency, and ≥2 splits. | Must | P0 |
| FR-ENG-05 | Model **Split** with account, memo, action, value (transaction currency), quantity (account commodity), reconcile state, reconcile date, and GUID. | Must | P0 |
| FR-ENG-06 | Enforce the **double-entry invariant**: the sum of split values in a transaction must be zero (balanced) before commit. | Must | P0 |
| FR-ENG-07 | Compute account **balances** (raw, cleared, reconciled) and running register balances efficiently. | Must | P0 |
| FR-ENG-08 | Model **Commodity** (currency or security): namespace, mnemonic/symbol, full name, fraction/SCU, and quote source metadata. | Must | P0 |
| FR-ENG-09 | Model **Price** entries (commodity, currency, date, value, source, type) forming a price database. | Must | P5 |
| FR-ENG-10 | Model **Lots** to associate splits for cost-basis / capital-gains tracking. | Should | P5 |
| FR-ENG-11 | Assign and preserve **GUIDs** for all first-class objects to enable stable round-tripping with GnuCash. | Must | P0 |
| FR-ENG-12 | Keep the engine free of UI and persistence dependencies so it is unit-testable in isolation. | Must | P0 |

### 5.2 Native document format, persistence, and shared-storage safety

FinvestLens is a **document-based app** with its **own native file format** (a single **SQLite** `.finvestlens` file, managed via GRDB). The in-memory engine model is the source of truth; SwiftData is **not** used. GnuCash XML is an import/export interchange format only (§5.3–5.4). See [Architecture §5.2 & §6](architecture.md).

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-DAT-01 | Open and save the app's **own native document** — a single `.finvestlens` **SQLite file** (via GRDB) — with its own registered file type/UTI. | Must | P1 |
| FR-DAT-02 | Provide a SQLite schema (GRDB migrations) mapping to the engine model, preserving imported GUIDs and KVP slots. | Must | P1 |
| FR-DAT-03 | Support multiple **documents** (open, create, switch, recent files); each document is self-contained. | Should | P1 |
| FR-DAT-04 | Handle schema **migration** across app versions without data loss. | Must | P1 |
| FR-DAT-05 | Ensure **transactional integrity**: partial/invalid transactions never persist; the double-entry invariant holds in storage. | Must | P1 |
| FR-DAT-06 | Allow a document to live on a **network share (NAS)** and enforce **single-writer locking** via an application-level lock file (holder metadata + heartbeat + stale-lock detection); offer read-only open when locked elsewhere. | Must | P1 |
| FR-DAT-07 | Edit against a **local working copy**; write back to the document **only on explicit Save (⌘S) or autosave** — never continuous background sync. Write-back is **atomic** under file coordination and never leaves the document corrupted on crash or conflicting write. | Must | P1 |
| FR-DAT-08 | Detect and surface **external-change conflicts** (out-of-band edits / bypassed lock) instead of silently overwriting. | Should | P1 |
| FR-DAT-09 | Support **discarding a working session**: closing without saving (or **Revert**) abandons unsaved changes; the on-disk document reflects only the last save. Retain the opened-state snapshot to enable **Revert to opened version**. | Must | P1 |
| FR-DAT-10 | **Autosave is user-configurable** (interval, or off). Provide crash recovery from the local working copy. | Should | P2 |

### 5.3 GnuCash XML import (primary interoperability)

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-IMP-01 | Import the **GnuCash XML** file format, both uncompressed and **gzip-compressed**. | Must | P1 |
| FR-IMP-02 | Parse and map: book, commodities, accounts (hierarchy), transactions, splits, and prices. | Must | P1 |
| FR-IMP-03 | Import **scheduled transactions** (`sx:`) and their recurrence rules. | Should | P4 |
| FR-IMP-04 | Import **budgets**. | Could | P4 |
| FR-IMP-05 | Import **business objects** (customers, vendors, employees, invoices, bills, jobs, terms, tax tables). | Could | P7 |
| FR-IMP-06 | Preserve all **GUIDs**, slots/key-value data, and unrecognised elements sufficiently to round-trip. | Must | P1 |
| FR-IMP-07 | Report a clear **import summary** (counts, warnings, unsupported elements) and fail safely on malformed files. | Must | P1 |
| FR-IMP-08 | Validate that the double-entry invariant holds on imported data; surface imbalances rather than silently altering data. | Must | P1 |

### 5.4 GnuCash XML export

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-EXP-01 | Export to **GnuCash XML** (compressed and uncompressed) that GnuCash desktop can reopen. | Must | P3 |
| FR-EXP-02 | Achieve **round-trip fidelity**: import → export → re-import yields structurally equivalent data (GUIDs, slots, relationships) for all supported object types; monetary amounts match **within a rounding tolerance** (exact `gnc_numeric` parity is not required). Verified by automated tests. | Must | P3 |
| FR-EXP-03 | Preserve GUIDs, slots, and unmodified elements captured on import. | Must | P3 |
| FR-EXP-04 | Emit valid namespaced XML matching the GnuCash schema version FinvestLens targets. | Must | P3 |

### 5.5 Chart of accounts

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-COA-01 | Display accounts as a **hierarchical tree** with balances (in account commodity and, where relevant, converted to a base currency). | Must | P2 |
| FR-COA-02 | Create, edit, move (reparent), hide, and delete accounts, with guards against deleting accounts that hold transactions. | Must | P2 |
| FR-COA-03 | Provide **account templates / new-book assistant** to set up a starter chart of accounts by locale/business type. | Should | P4 |
| FR-COA-04 | Mark accounts as **placeholder** (no direct postings) and **hidden**. | Should | P2 |
| FR-COA-05 | Show totals, subtotals, and net worth roll-ups. | Should | P2 |
| FR-COA-06 | Support **account codes** and **renumber sub-accounts** (bulk re-code by hierarchy). | Could | P2 |

### 5.6 Transaction register (ledger)

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-REG-01 | Provide a **register/ledger** view per account for entering and editing transactions, with running balance. | Must | P2 |
| FR-REG-02 | Support **simple** (two-split) and **split** (multi-split) transaction entry, enforcing balance. | Must | P2 |
| FR-REG-03 | Offer register view styles (basic ledger, auto-split, transaction journal) analogous to GnuCash. | Should | P2 |
| FR-REG-04 | Provide **autofill** of payee/description and last-used splits, and keyboard-driven entry. | Should | P2 |
| FR-REG-05 | Support **transfer** between accounts (Transfer Funds dialog), duplicate, delete, void, and mark reconcile state inline. | Must | P2 |
| FR-REG-06 | **Find/Search** transactions by date, amount, payee, memo, account, reconcile state (multi-criteria search dialog). *(Upgraded to an operator query language in `FR-FIND-01`.)* | Should | P2 |
| FR-REG-07 | Handle **multi-currency/commodity transactions** with per-split exchange rates. | Must | P5 |
| FR-REG-08 | Transaction operations: **add reversing transaction**, **jump** to the other account's register, copy/paste, and remove splits. | Should | P2 |
| FR-REG-09 | Provide a **General Ledger / General Journal** view (combined register across multiple accounts). | Could | P2 |
| FR-REG-10 | **Attach/associate an external file or URL** to a transaction (document link / "paperclip"). | Could | P6 |
| FR-REG-11 | **Print checks** from transactions with configurable check formats. | Could | P4 |

### 5.7 Reconciliation

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-REC-01 | Provide a **reconciliation** workflow: statement date and ending balance, mark cleared items, show running difference, finish when reconciled to zero. | Must | P4 |
| FR-REC-02 | Persist reconcile state (n/c/y) and reconcile dates on splits. | Must | P4 |
| FR-REC-03 | Support opening-balance reconciliation and re-opening a previous reconciliation. | Should | P4 |

### 5.8 Scheduled (recurring) transactions

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-SCH-01 | Create **scheduled transactions** from a template with recurrence rules (daily, weekly, monthly, yearly, nth-weekday, etc.). | Should | P4 |
| FR-SCH-02 | Support variables/formulas in scheduled splits (e.g. loan payment components). | Could | P4 |
| FR-SCH-03 | Notify/remind and allow **review before posting** upcoming scheduled transactions ("since last run" assistant). | Should | P4 |
| FR-SCH-04 | Provide a **loan/mortgage assistant** to generate an amortized scheduled transaction. | Could | P5 |

### 5.9 Investments, commodities, and prices

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-INV-01 | Support **stock and mutual-fund accounts** denominated in a security commodity. | Must | P5 |
| FR-INV-02 | Provide a **Price Editor / database**: manual entry and listing of commodity prices over time. | Must | P5 |
| FR-INV-03 | Retrieve **online price quotes** for securities and currencies via **pluggable providers**, with user-triggered and scheduled refresh, a user-chosen default and fallback order. Results populate the Price DB. | Should | P5 |
| FR-INV-03a | Provide a **keyless "yfinance-like" Yahoo provider** (no API key) for current and **historical** quotes, dividends, and splits — the default out-of-box source. | Should | P5 |
| FR-INV-03b | Support **keyed providers** where the user enters an **API key** (stored in the **Keychain**), including **EODHD**, Alpha Vantage, Finnhub, and Twelve Data. Keys are entered by the user in Settings and sent only to that provider. | Should | P5 |
| FR-INV-03c | Support **EODHD** specifically for **historical prices of delisted securities** (and deep multi-decade history). | Should | P5 |
| FR-INV-03d | Support **historical price backfill** over a date range (not just latest), to populate the Price DB for valuation and reports. | Should | P5 |
| FR-INV-03e | Surface a clear **terms-of-use notice** for unofficial/keyless sources (e.g. Yahoo endpoints are unaffiliated, personal-use); let users pick sanctioned keyed providers instead. | Should | P5 |
| FR-INV-04 | Provide a **Stock Transaction Assistant** guiding buy/sell, dividends (cash and reinvested), return of capital, fees, and stock splits/mergers through a step-by-step flow. | Should | P5 |
| FR-INV-05 | Compute **capital gains/losses** using lots (cost basis) via a **Lots Editor**, rather than manual computation. | Should | P5 |
| FR-INV-06 | Value holdings and portfolios in a chosen base currency using the price database. | Should | P5 |
| FR-INV-07 | Provide a **Security Editor** to add/edit commodities (securities & currencies) and configure their online-quote source. | Should | P5 |

### 5.10 Multiple currencies

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-CUR-01 | Support accounts and transactions in **any ISO currency** and user-defined commodities. | Must | P5 |
| FR-CUR-02 | Handle currency-crossing transactions with explicit **exchange rates** per split. | Must | P5 |
| FR-CUR-03 | Optionally use **trading accounts** for multi-currency balancing (GnuCash's trading-accounts model). | Could | P5 |
| FR-CUR-04 | Retrieve **currency exchange rates** as prices. | Should | P5 |

### 5.11 Reports and charts

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-RPT-01 | Provide core reports: **Account Summary / Balance Sheet**, **Income & Expense (Profit & Loss)**, **Net Worth over time**, **Transaction Report**, **Cash Flow**. | Should | P4 |
| FR-RPT-02 | Provide investment reports: **Portfolio value**, **Advanced Portfolio**, **Price scatter**. | Could | P5 |
| FR-RPT-03 | Provide charts (bar/line/pie) for income/expense, net worth, and portfolio, following the app's data-visualization design system. | Should | P4 |
| FR-RPT-04 | Allow date-range, account selection, and currency options; save report configurations. | Should | P4 |
| FR-RPT-05 | **Export/print** reports to PDF and share via the platform share sheet. | Should | P4 |

### 5.12 Budgets

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-BUD-01 | Create **budgets** with per-account, per-period planned amounts. | Could | P4 |
| FR-BUD-02 | Show **budget vs. actual** comparison reports. | Could | P4 |

### 5.13 Business features (SMB)

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-BUS-01 | Manage **Customers** and **Vendors** (contact, terms, tax table, currency). | Could | P7 |
| FR-BUS-02 | Manage **Employees** and expense vouchers. | Could | P7 |
| FR-BUS-03 | Create, post, and print **Invoices** (A/R) and **Bills** (A/P). | Could | P7 |
| FR-BUS-04 | Support **Jobs**, **Billing Terms**, and **Sales Tax Tables**. | Could | P7 |
| FR-BUS-05 | Record and apply **customer/vendor payments**; track A/R and A/P aging. | Could | P7 |
| FR-BUS-06 | Store **company/business information** used on documents. | Could | P7 |

### 5.14 Bank/financial file import (core) and extended formats

**CSV, QIF, and OFX/QFX import are first-class, core features** — the primary way users bring in bank, card, and brokerage data. They are **reimplemented natively in Swift** (not ported from GnuCash's importers); see [Architecture §5.8a](architecture.md). All three feed the shared **Import Matcher**.

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-XIO-01 | Import **QIF** (Quicken Interchange Format) files — native Swift parser (accounts, categories, transactions, splits, investment actions). | Must | P4 |
| FR-XIO-02 | Import **OFX / QFX** files — native Swift parser handling **OFX v1 (SGML)** and **OFX v2 (XML)** and Quicken's QFX variant (bank, credit-card, and investment statements). | Must | P4 |
| FR-XIO-03 | Import **CSV** transactions and prices with a **configurable column mapping** and preview. | Must | P4 |
| FR-XIO-05 | Provide a **Generic Transaction Import Matcher**: match incoming transactions to existing ones, detect duplicates, and assign destination accounts with a confidence-based UI (shared by CSV/QIF/OFX and later formats). | Must | P4 |
| FR-XIO-08 | Support **save/load of CSV import settings** (column-mapping profiles) for repeat imports. | Should | P4 |
| FR-XIO-06 | Export **CSV** for accounts, transactions, and prices. | Should | P4 |
| FR-XIO-04 | Import **MT940 / MT942** and **CAMT.053** (ISO 20022) bank statement formats. | Could | P8 |
| FR-XIO-07 | **Online bank sync** via modern aggregation APIs — **SimpleFIN** / **GoCardless (Nordigen)** and, for Australia, the **Consumer Data Right (CDR / Open Banking)** via an **accredited intermediary** — feeding the Import Matcher. Optional, explicitly consented, cloud-mediated; the app stays fully functional offline. Investigate (regulatory diligence for CDR); later release. | Could | P8 |

### 5.15 Platform integration

**Import/export is a desktop-class capability.** GnuCash XML import/export, bank-file import (CSV/QIF/OFX-QFX), CSV export, and report/PDF export are **macOS (and iPadOS where feasible)** features. On **iOS (iPhone)**, it is acceptable for FinvestLens to support only **opening** an existing book and **creating/editing** new books — import and export need not be offered. This keeps the compact iPhone experience focused on quick entry and review; users move data in and out on the Mac (or iPad), with the same document opened everywhere via Files/iCloud (`FR-PLT-02`).

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-PLT-01 | Adaptive SwiftUI UI: multi-column/sidebar on macOS & iPad, compact navigation on iPhone. | Must | P2 |
| FR-PLT-02 | **File-level sync**: because the document is a file, support iCloud Documents / Files placement with `NSFilePresenter`-based external-change handling and `NSFileVersion` conflict resolution (consistent with the NAS write-back path). *(Replaces the earlier SwiftData+CloudKit plan.)* | Should | P6 |
| FR-PLT-03 | System integration: **Shortcuts / App Intents**, Spotlight, **Quick Look** for `.finvestlens` (and `.gnucash`) files, Share Sheet, Home-screen **widgets** (net worth, budget). | Could | P6 |
| FR-PLT-04 | Register FinvestLens's **own** `.finvestlens` document type (UTI, `public.database`) and register as an importer/exporter for GnuCash file types. | Must | P1/P3 |
| FR-PLT-05 | Standard document behaviors (open/save/save-as, autosave, recent files, versions) across macOS/iPadOS/iOS. | Should | P1 |
| FR-PLT-06 | **Platform capability scoping.** GnuCash XML import/export, bank-file import, CSV export, and report/PDF export are provided on **macOS** (and **iPadOS** as feasible). On **iOS (iPhone)** these are **out of scope**; iOS supports opening existing books and creating/editing new ones only. | Must | P6 |

### 5.16 Planning, forecasting & insights (Microsoft Money–inspired)

Features that add consumer-grade **planning and guidance** on top of the accounting engine — none compromises double-entry integrity; each is a projection or guided workflow over the engine. See the [enhancement study](enhancements-msmoney.md).

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-PLAN-01 | **Bill reminders & Financial Calendar**: track recurring bills/deposits (over scheduled transactions) with due dates, pay/skip/enter, overdue flags, and a calendar view. | Should | P4 |
| FR-PLAN-02 | **Cash-flow forecast**: project future account balances from scheduled bills/deposits over a horizon. | Should | P4 |
| FR-PLAN-03 | **What-if scenarios**: model a one-off change (large purchase, income change, extra payment) and see the effect on projected cash flow, without altering actual data. | Could | P5 |
| FR-PLAN-04 | **Budget rollover / envelope** semantics and **projected end-of-period** budget-vs-actual (extends `FR-BUD-*`). | Could | P4 |
| FR-PLAN-05 | **Alerts (Advisor-FYI style)**: a rules engine raising proactive alerts — bill due, projected low/negative balance, over budget, price target hit, unusual spend — delivered via in-app, **notifications**, and **widgets**. | Should | P6 |
| FR-PLAN-06 | **Payee management + auto-categorization rules**: user-editable payee rename and category/account assignment rules, applied on import (complements the Import Matcher). *(Realized by the general rules engine — see `FR-RULE-01`.)* | Should | P4 |
| FR-PLAN-07 | **Portfolio enhancements**: **watch lists** (securities not held), **asset-allocation** breakdown, and **rate-of-return / performance** (extends `FR-INV-*`). | Should | P5 |
| FR-PLAN-08 | **Home dashboard**: customizable overview surfacing balances, upcoming bills, budget status, **net-worth trend**, and alerts; drives Home-screen widgets. | Should | P6 |
| FR-PLAN-09 | **Onboarding / setup assistant**: friendly first-run flow to create accounts and a starter chart of accounts (broadens `FR-COA-03`). | Should | P4 |
| FR-PLAN-10 | **Debt Reduction Planner**: order liabilities, apply extra payments, and compute payoff date/interest saved (snowball & avalanche strategies). | Could | P9 |
| FR-PLAN-11 | **Lifetime Planner**: long-range financial/retirement projection from income, expenses, assets, retirement accounts, taxes, inflation, and life events → projected net worth and goal feasibility over a lifetime. | Could | P9 |
| FR-PLAN-12 | **Tax estimator & tax-line tagging**: estimate liability, project capital gains, tag tax-related categories, track deductions (complements TXF export). | Could | P9 |
| FR-PLAN-13 | **Insights & comparison reports**: spending-by-category trends and period-vs-period comparisons with plain-language summaries. | Could | P9 |
| FR-PLAN-14 | **Time & mileage tracking** for small-business use (extends `FR-BUS-*`). | Could | P7 |
| FR-PLAN-15 | **Emergency Records Organizer**: a secure area to store key records (insurance, accounts, contacts). | Could | P9 |
| FR-PLAN-16 | **Financial wellbeing score** (Frollo-inspired): an explainable indicator of financial health (savings rate, spending trends, debt ratios, cash buffer) surfaced on the dashboard — transparent, not a black box. | Could | P9 |
| FR-PLAN-17 | **Financial summary export ("passport")** (Frollo-inspired): a curated, user-initiated PDF snapshot of net worth, income, and expenses for sharing (e.g. loan applications). | Could | P9 |

### 5.17 Automation, tags & goals (Firefly III–inspired)

Automation and organization features that layer onto the engine. See the [enhancement study](enhancements-firefly.md).

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-RULE-01 | **Rules engine**: ordered **rule groups** of rules; each rule has **triggers** (strict = all / non-strict = any) over transaction fields and **actions** (set category/budget/tags/description/notes, convert type, link to bill, allocate to a savings goal). Supports a **stop-processing** flag. *(Supersedes `FR-PLAN-06`.)* | Should | P4 |
| FR-RULE-02 | Rules run **on create/update, on import**, and **manually**; can be **applied to historical** transactions over a date/account range with a **preview** before committing. | Should | P5 |
| FR-TAG-01 | **Tags**: cross-cutting labels on transactions (optional date/location), independent of the account/category hierarchy; usable in search and rules. | Should | P2 |
| FR-GOAL-01 | **Savings goals (piggy banks)**: divide an asset account's balance into named goals; add/remove money; **link transfers** so they auto-allocate; **group** goals; optionally link a goal to a bill. | Should | P5 |
| FR-FIND-01 | **Operator search language**: a query syntax (`type:`, `from:`/`to:`, `amount`, `category:`, `tag:`, date operators with `d/w/m/y` offsets, notes/attachment operators, negation with `-`), with **saved searches**. Shares its grammar with rule triggers. *(Upgrades `FR-REG-06`.)* | Should | P4 |
| FR-BILL-01 | **Bill matching**: bills carry an **expected amount/range and interval**; transactions auto-match to bills; surface **paid / unpaid / overdue** status. *(Extends `FR-PLAN-01`.)* | Should | P4 |
| FR-BUD-03 | **Auto-budgets**: budgets that **auto-replenish** each period (fixed or rollover); support a **zero-based** budgeting workflow. *(Extends `FR-BUD-*`, `FR-PLAN-04`.)* | Could | P4 |
| FR-RULE-03 | **Default category taxonomy + heuristic auto-categorisation** (Frollo-inspired): ship a standard category set and auto-suggest categories/merchant-name cleanup on import, complementing the rules engine and Import Matcher (optional on-device enrichment later). | Should | P4 |
| FR-GOAL-02 | **Savings challenges** (Frollo-inspired): gamified, time-boxed savings challenges layered on savings goals, with in-app prompts/notifications. | Could | P9 |

### 5.18 On-device intelligence (Apple Intelligence)

An optional layer that runs entirely on-device over Apple's **Foundation Models** framework — no financial data leaves the device — and never mutates the book without review. The contract is **the model proposes; deterministic code disposes**: model output is typed, parsed tolerantly, resolved against the real chart of accounts, and arithmetically cross-checked before a reviewed result is applied. Every entry point is **availability-gated** and degrades gracefully when Apple Intelligence is unavailable. See [Architecture §11](architecture.md#11-apple-intelligence-integration-intelligence-package).

| ID | Requirement | Pri | Phase |
|---|---|---|---|
| FR-AI-01 | **PDF statement import**: extract transactions from PDF bank/card statements (text extraction with an OCR fallback for scans) and stage them through the Import Matcher for review; matched register splits may be marked cleared (light reconciliation). | Could | P4 |
| FR-AI-02 | **Auto-categorisation**: propose an account/category for uncategorised transactions after deterministic rules, history, and heuristics — in import review and a dedicated Auto-Categorise panel. | Could | P4 |
| FR-AI-03 | **Invoice splitting**: read an invoice's line items and turn them into categorised splits on a transaction. | Could | P7 |
| FR-AI-04 | **Dividend statement import**: extract dividend components (franked/unfranked amounts, franking/imputation credits) and book them, including gross-up, after review. | Could | P5 |
| FR-AI-05 | **Budget suggestion**: derive per-line budget proposals from deterministic spending statistics for a reviewed, per-line apply. | Could | P4 |
| FR-AI-06 | **Forecast narration**: turn computed cash-flow-forecast facts into a plain-language headline and insights in the Cash Flow report. | Could | P5 |
| FR-AI-07 | **Smart Import (multi-PDF)**: classify each dropped PDF and route it — statements to `FR-AI-01` review, dividend statements to a verified booking, invoices matched to their transaction, split by line item, and re-dated to the invoice's economic date. | Could | P7 |
| FR-AI-08 | **Document links**: copy applied statements/invoices into the document folder and link them to their transaction via GnuCash's `assoc_uri` slot, round-trippable through GnuCash XML. | Could | P6 |

---

## 6. Non-functional requirements

| ID | Requirement |
|---|---|
| NFR-01 **Correctness** | Monetary math uses native `Decimal` (no binary-float error), rounded to each commodity's fraction. No transaction may persist unbalanced (within one minor unit). Round-trip import/export preserves structure/GUIDs/slots losslessly; amounts match within a rounding tolerance (test-enforced). |
| NFR-02 **Performance** | Open and render a book with 100k+ transactions responsively; register scrolling and balance computation stay smooth (target <100 ms interactions on current Apple hardware). Import of a large GnuCash file completes with progress feedback. |
| NFR-03 **Data integrity & safety** | Never lose or silently mutate user data; guard destructive actions; keep unrecognised imported data for round-tripping. Local-first; works fully **offline**. |
| NFR-04 **Platform support** | macOS, iPadOS, iOS on a shared codebase. Minimum OS versions to be finalized (target current − 1 major). Not every capability need be present on every platform: import/export is desktop-class (macOS/iPadOS); iPhone is open/create/edit only (`FR-PLT-06`). |
| NFR-05 **Accessibility** | Full VoiceOver, Dynamic Type, keyboard navigation, sufficient contrast, Reduce Motion support. |
| NFR-06 **Localization** | Localizable UI; correct locale-aware number, date, and currency formatting; right-to-left readiness. |
| NFR-07 **Privacy & security** | No financial data leaves the device except via user-initiated iCloud sync or export. No trades or transfers. Optional local authentication (Face ID / Touch ID) to open a book. |
| NFR-08 **Testability** | Engine and import/export covered by unit tests; round-trip corpus of real GnuCash files in CI. |
| NFR-09 **Maintainability** | Clear layering (engine / persistence / import-export / UI); idiomatic Swift; documented public APIs. |
| NFR-10 **Licensing** | GPLv3; interoperate with GnuCash via its XML format; no proprietary lock-in. |

---

## 7. Data model and interoperability

The engine model mirrors GnuCash's object graph so that XML mapping is direct:

```
Book
 ├─ Commodities         (currency | security)
 ├─ Accounts (tree)     type, commodity, SCU, parent, GUID, slots
 │    └─ Splits         value, quantity, reconcile-state, memo, action
 ├─ Transactions        currency, dates, num, description, splits[]
 ├─ Prices              commodity ↔ currency @ date
 ├─ Lots                (cost-basis grouping of splits)
 ├─ Scheduled Txns      template + recurrence
 ├─ Budgets             per-account per-period amounts
 └─ Business objects    customers, vendors, employees, invoices, bills, jobs, terms, tax tables
```

**Numeric representation.** Amounts use native `Decimal` (wrapped in `Money` with a commodity), rounded to the commodity's fraction — not GnuCash's rational `gnc_numeric`. Every split stores both *value* (transaction currency) and *quantity* (account commodity), enabling multi-currency and share accounting.

**GUID preservation.** Every first-class object retains its GnuCash GUID on import and re-emits it on export. Unrecognised elements and key-value "slots" are preserved to protect round-trip fidelity.

**Interchange, not database compatibility.** FinvestLens reads/writes the GnuCash **XML** format only. The GnuCash SQL backends are out of scope (NG1).

---

## 8. UX principles (platform-specific)

- **macOS** — Multi-pane document window: accounts sidebar, register main area, inspector; toolbar, keyboard shortcuts; standard document lifecycle. GnuCash's menu set (File, Edit, View, Transaction, Business, Reports, Tools, Windows, Help) maps to a native macOS menu bar; the distinct GnuCash windows (Account Tree, Register/General Journal, Report, Reconcile, Scheduled Transactions) map to panes/sheets/tabs.
- **iPadOS** — Sidebar + detail split view; pointer/keyboard support; drag-and-drop; multitasking.
- **iOS** — Compact, navigation-stack UI optimized for quick transaction entry and review; widgets and Shortcuts for glanceable balances. Open an existing book or create/edit a new one; **import and export (GnuCash, bank files, CSV, PDF) are not offered on iPhone** — those flows live on macOS/iPadOS (`FR-PLT-06`).
- **Shared** — One design language; Dark Mode; SF Symbols; native controls; charts consistent with the project's data-visualization standards.

---

## 9. Milestones (mapped to phases)

1. **P0 Foundation** — engine types, `Decimal`-based `Money`, double-entry invariant, unit tests. *(FR-ENG-\*)*
2. **P1 Document & Import** — GRDB SQLite `.finvestlens` open/save; NAS locking & atomic write-back; GnuCash XML import + summary. *(FR-DAT-\*, FR-IMP-\*)*
3. **P2 Core UX** — chart of accounts + register editing. *(FR-COA-\*, FR-REG-\*)*
4. **P3 Export** — GnuCash XML export + round-trip tests. *(FR-EXP-\*)*
5. **P4 Everyday finance & bank import** — reconciliation, scheduled txns, core reports, budgets; native CSV/QIF/OFX-QFX import + Import Matcher, CSV export. *(FR-REC/SCH/RPT/BUD-\*, FR-XIO-01/02/03/05/06/08)*
6. **P5 Investments & currency** — commodities, prices, quotes, capital gains, multi-currency. *(FR-INV/CUR-\*)*
7. **P6 Sync & polish** — file-level sync, Shortcuts, widgets, accessibility. *(FR-PLT-\*)*
8. **P7 Business features** — customers/vendors, invoices/bills, tax tables, A/R–A/P. *(FR-BUS-\*)*
9. **P8 Extended import/export** — MT940/MT942 + CAMT.053 bank-statement import; online bank sync; PDF export. *(FR-XIO-04/07, FR-RPT-05)*
10. **P9 Planning & insights** — Debt Reduction Planner, Lifetime Planner, tax estimator/tagging, insights/comparison reports. *(FR-PLAN-10..13, 15..17, FR-GOAL-*)* Earlier planning features (bill reminders, forecast, alerts, payee rules, portfolio, dashboard, onboarding) map to P4–P7. *(FR-PLAN-01..09, 14)*

---

## 10. Success metrics

- **Interoperability:** ≥99% of objects in a representative corpus of real GnuCash files round-trip without loss; zero balance-integrity failures.
- **Correctness:** 0 unbalanced transactions persisted; engine test coverage ≥90% of core logic.
- **Performance:** books of 100k transactions open and scroll within target latencies (NFR-02).
- **Adoption signal (post-launch):** migrating GnuCash users can import, use daily, and export back successfully.

---

## 11. Risks and open questions

| # | Risk / question | Notes |
|---|---|---|
| R1 | GnuCash XML schema breadth (business objects, slots, SX) is large. | Prioritise core objects; preserve-and-passthrough unknowns to protect round-trip. |
| R2 | Exact-decimal performance at scale. | Benchmark the rational type early; cache balances. |
| R3 | Online quote sources change/rate-limit. | Make quote sources pluggable; degrade gracefully offline. |
| R4 | SQLite safety/locking on network shares (SMB/NFS). | App-level lock file + heartbeat, local working copy, coordinated atomic write-back (Architecture §6); load-test on real NAS in P1. |
| Q1 | Minimum OS versions? | Target current − 1; confirm against required SwiftUI/document features. |
| Q2 | Which GnuCash XML schema version to target for export? | Match current stable GnuCash (v5-era) format. |
| Q3 | Product/trademark naming relative to GnuCash. | FinvestLens is unaffiliated; avoid implying endorsement. |

---

## 12. Out of scope (recap)

SQL backends (NG1); GnuCash's exact UI (NG2); Scheme/Python scripting (NG3); financial advice (NG4); executing trades/payments/transfers (NG5); online banking DirectConnect/AqBanking in early releases (FR-XIO-07).

---

## 13. Dependencies

- **GRDB** (SQLite) for the native `.finvestlens` document store — the **single external** dependency. Everything else is first-party Apple frameworks or hand-written native Swift (see [Architecture §9](architecture.md#9-dependencies)).
- **Apple frameworks**: SwiftUI + AppKit/UIKit (UI); Foundation (`Decimal`, `NSFileCoordinator`/`NSFilePresenter`/`NSFileVersion`, `URLSession`); Swift Charts; App Intents (Shortcuts); UniformTypeIdentifiers (the `.finvestlens` UTI); Observation; CryptoKit (document fingerprint); Compression (gzip for GnuCash XML); Security (Keychain for quote API keys); LocalAuthentication (optional book lock); and — for the on-device intelligence layer (§5.18) — FoundationModels, Vision, and PDFKit.
- A quote-retrieval mechanism for FR-INV-03 / FR-CUR-04 — native pluggable providers over `URLSession` (no external SDK).
- A corpus of real/sample GnuCash XML files for round-trip CI (NFR-08).

---

## 14. Traceability

Every requirement carries a stable `FR-*` / `NFR-*` ID and a target phase, so implementation tasks, tests, and this PRD stay linked. Round-trip fidelity (FR-EXP-02) and the double-entry invariant (FR-ENG-06) are the two hardest gates and must have dedicated automated tests.

---

## 15. Glossary

| Term | Meaning |
|---|---|
| **Book** | Top-level container for accounts and data (a file). |
| **Account** | Typed, named bucket in a hierarchy, denominated in a commodity. |
| **Transaction** | Dated event of ≥2 balanced splits. |
| **Split** | One leg of a transaction posted to an account (value + quantity). |
| **Commodity** | A currency or a security (stock/fund). |
| **Price** | A commodity's value in another commodity at a date. |
| **Lot** | Grouping of splits for cost-basis / capital-gains tracking. |
| **SCU** | Smallest Currency Unit / commodity fraction (e.g. cents = 1/100). |
| **Reconcile state** | Split status: not (n), cleared (c), reconciled (y). |
| **Scheduled transaction (SX)** | Template + recurrence generating future transactions. |
| **A/R, A/P** | Accounts Receivable / Payable (business). |

---

## 16. References

- GnuCash Documentation index — https://gnucash.org/docs.phtml
- Documentation source (DocBook) — https://github.com/Gnucash/gnucash-docs (`C/guide`, `C/manual`)
- **Tutorial and Concepts Guide** (v5) — https://www.gnucash.org/docs/v5/C/gnucash-guide/
  - Importing Data — `chapter_importing.html`; Investments — `chapter_invest.html`; Business Features — `chapter_bus_features.html`
  - Capital Gains — `chapter_capgain.html`; Multiple Currencies — `chapter_currency.html`; Budgets — `chapter_budgets.html`; Auxiliary File Formats — `appendixd.html`
- **Help Manual** (v5) — https://www.gnucash.org/docs/v5/C/gnucash-manual/ — chapters (DocBook source `C/manual/`):
  - Introduction; Getting Started; **Windows & Menus** (`ch_GUIMenus`); **Accounts** (`ch_Account-Actions`); **Transactions & Import** (`ch_Transactions`); **Business** (`ch_Business`); **Reports** (`ch_Reports`); **Tools & Assistants** (`ch_Tools_Assistants` — Mortgage/Loan, Stock Transaction Assistant, Online Banking/AqBanking, Price Editor, Security Editor, Loan Calculator, Lots Editor); **Finance::Quote** (`ch_Finance-Quote`); Customize; TXF tax categories (`txf-categories`).
- Project [README](../README.md) and [LICENSE](../LICENSE).

> **Note:** This PRD is grounded in the public GnuCash documentation but is an independent specification for FinvestLens. FinvestLens is not affiliated with or endorsed by the GnuCash project.
