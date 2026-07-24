# FinvestLens — Phased Implementation Plan

| | |
|---|---|
| **Document status** | **All phases P0–P9 complete** (v1.0 was P0–P6, 13 July 2026; P7 business, P8 extended import, and P9 planning & insights since), **plus the Jul 2026 usability/performance and report-quality redesigns**. Online bank sync skipped to [deferred.md](deferred.md). |
| **Last updated** | 2026-07-24 |
| **Scope** | The build plan: phases, workstreams, tasks, dependencies, and exit criteria |
| **Companions** | [PRD](prd.md) · [Architecture](architecture.md) · [Porting Strategy](porting.md) · [Implemented](implemented.md) · [Deferred backlog](deferred.md) · [Money study](enhancements-msmoney.md) · [Firefly study](enhancements-firefly.md) · [Frollo study](enhancements-frollo.md) |

This is the authoritative **delivery schedule and status record**. It sequences the requirements from the [PRD](prd.md) (`FR-*`), the architecture decisions ([`ADR-*`](architecture.md)), and the porting map ([Porting §2](porting.md)) into ten phases (P0–P9), and records where each one stands. Each phase lists its **objective, workstreams/tasks, dependencies, deliverables, exit criteria, test focus, and risks**.

### Phase status

| Phase | Status | Notes |
|---|---|---|
| **P0 — Foundation** | ✅ Complete | |
| **P1 — Native document & import** | ✅ Complete | |
| **P2 — Core UX** | ✅ Complete | |
| **P3 — Export & round-trip** | ✅ Complete | Lossless round-trip GnuCash-verified. |
| **P4 — Everyday finance & bank import** | ✅ Complete | |
| **P5 — Investments & multi-currency** | ✅ Complete | Investment reports GnuCash-verified to the cent. |
| **P6 — Sync, dashboard, alerts & polish** | ✅ Complete | Plus the post-1.0 **Apple Intelligence** layer (FR-AI-01…08). |
| **P7 — Business features** | ✅ Complete | Engine + persistence + XML round-trip + UI. |
| **Usability & performance redesign** | ✅ Complete (24 Jul 2026) | A post-P7 pass over the P2/P4/P6 surfaces, driven by four audits ([usability-review.md](usability-review.md), [performance-review.md](performance-review.md)): one expandable register, plain language, the non-scrolling tile-board dashboard, auto-clear-first reconcile, one-click prices (⌘⇧U), a single status overlay, session restoration, memoised async reports, and the EOFY Financial Year Pack. Narrative in [implemented.md](implemented.md). |
| **Report-quality redesign** | ✅ Complete (24 Jul 2026) | Statements at annual-report standard — face-and-notes presentation from the user's own tree, ASC 274 ordering, accounting typography, comparatives, incl. the Trial Balance — plus the Financial Review and Investment Review slide decks with validator-grounded on-device insights. Plan/research: [report-redesign.md](report-redesign.md); design: [architecture.md §5.6a](architecture.md); narrative in [implemented.md](implemented.md). |
| **P8 — Extended import** | ✅ Complete (24 Jul 2026) | MT940/MT942 + CAMT.053 importers feed the Import Matcher; format auto-detection incl. content sniffing. Online bank sync (FR-XIO-07) **skipped by decision (24 Jul 2026)** — moved to [deferred.md](deferred.md) §5. |
| **P9 — Planning & insights** | ✅ Complete (24 Jul 2026) | Debt & Lifetime planners, tax estimator, Spending Insights, wellbeing score, passport PDF, savings challenges, Emergency Records, audit log — design in [planning-design.md](planning-design.md). |

**Every phase P0–P9 is delivered**; a set of low-priority tails deferred *within* them is tracked, ranked, in [deferred.md](deferred.md). The narrative of what was built, with the audits and measurements behind it, is in [implemented.md](implemented.md).

---

## 1. Delivery principles

- **Engine-first, bottom-up.** Nothing is built on an unproven foundation. `Money` and the engine model come before persistence; persistence before UI.
- **Every phase is releasable.** Each phase ends at a usable, demoable, test-green state.
- **Protocol boundaries.** Persistence (`Repository`), file IO, XML interchange, and quotes sit behind protocols (Architecture P4) so layers evolve independently.
- **Test-gated.** A phase is "done" only when its **exit criteria** and quality gates (§14) pass. Round-trip fidelity (`FR-EXP-02`) and the double-entry invariant (`FR-ENG-06`) are hard gates.
- **Vertical slices where possible.** Within a phase, prefer thin end-to-end slices (one account type, one report) over broad-but-shallow work.
- **Native-first.** Reach for Apple frameworks; add a dependency only per the architecture's budget (§9 there).

---

## 2. Module (SPM target) structure — establish in P0

```
FinvestLens/                     (Xcode project, existing)
 └─ Packages/
     ├─ Engine          pure Swift: Money, model, Scrub, Query, GncGUID, KvpFrame
     ├─ Persistence     GRDB store + Repository protocols + Document/FileLock
     ├─ Interchange     GnuCash XML codec · CSV/QIF/OFX parsers · Import Matcher
     ├─ Quotes          QuoteProvider protocol + provider adapters
     ├─ Reports         report computation services (+ chart models)
     ├─ Rules           rules engine + operator search grammar
     └─ FeatureUI       SwiftUI views/view-models (per platform)
FinvestLensApp targets (macOS/iPadOS/iOS) depend on FeatureUI → downward only.
```

Dependencies point downward only; `Engine` builds/tests with nothing above it (`FR-ENG-12`).

---

## 3. Cross-cutting workstreams (run continuously from P0)

| Stream | What | Starts |
|---|---|---|
| **Testing & CI** | Swift Testing; CI runs unit + round-trip + perf on each PR; coverage tracked | P0 |
| **Fixture corpus** | Curated `.gnucash` files (small→large, personal/business, multi-currency, investments) under `Tests/Fixtures`; a synthetic 100k-txn generator | P1 |
| **Design system** | SwiftUI component kit, dark/light, Dynamic Type; charts per the [dataviz](enhancements-firefly.md) standards | P2 |
| **Performance harness** | Open/scroll/import/save benchmarks vs NFR-02; NAS write-back tests. *An `os_signpost` + DEBUG over-budget harness (`Perf`) now wraps the hot paths (Jul 2026).* | P1 |
| **Accessibility & localization** | VoiceOver, Dynamic Type, locale-aware formatting; string catalogs | P2 (audit in P6) |
| **Security** | Keychain for API keys; optional Face/Touch ID to open a book | P5 (keys), P6 (lock) |

---

## 4. Phase P0 — Foundation (engine core)

**Objective.** A standalone, pure-Swift accounting engine with exact-enough money and enforced double-entry — no persistence, no UI.

**Workstreams & tasks**
- **Project setup:** create the SPM targets (§2); wire Swift Testing + CI; add the GPLv3 file-header template check.
- **`Money`** over `Foundation.Decimal` (+ `Commodity` association): arithmetic, comparison, rounding to commodity fraction via `NSDecimalRound`. *(FR-ENG-01, ADR-1)*
- **`GncGUID`** — 16 bytes with GnuCash 32-hex (no-dash) codec. *(FR-ENG-11, ADR-3)*
- **`KvpFrame`/`KvpValue`** recursive value types covering GnuCash slot types. *(groundwork for FR-IMP-06, ADR-4)*
- **Model:** `Commodity`/`CommodityTable` (`FR-ENG-08`); `Account` + all account types (`FR-ENG-02/03`); `Split` (`FR-ENG-05`); `Transaction` with the **balancing invariant** (`FR-ENG-04/06`); `Book` aggregate.
- **Balances:** raw/cleared/reconciled + running balance. *(FR-ENG-07)*
- **`Scrub`** integrity/repair (imbalance→Imbalance acct, orphans). *(FR-ENG-06, FR-IMP-08)*

**Dependencies.** None.
**Deliverables.** `Engine` package; test suite; CI green.
**Exit criteria.** Engine compiles alone; construct transactions in code and balances are enforced/correct (tolerant asserts); ≥90% coverage of core logic; unbalanced transactions cannot be committed.
**Test focus.** `Money` ops with tolerance; balancing invariant; Scrub on malformed graphs.
**Risks.** ADR-1 rounding choices (PR1) — settle the per-commodity rounding mode here (see §17).

---

## 5. Phase P1 — Native document & GnuCash import

**Objective.** Open/save the native `.finvestlens` SQLite document safely (incl. NAS), and import GnuCash XML into it.

**Workstreams & tasks**
- **GRDB store & schema:** tables mapping the engine model; GUID + `KvpFrame`-as-JSON columns; `DatabaseMigrator`; `meta` (schema version + change counter). *(FR-DAT-01/02/04, ADR-2)*
- **Repository protocols:** `BookStore`, `AccountStore`, `TransactionStore`, `PriceStore`, … isolating GRDB. *(ADR-2, ADR-5)*
- **Document lifecycle:** open→lock→**local working copy**→materialize `Book`; edit locally; **explicit Save/autosave**→checkpoint→atomic write-back; **Discard/Revert**; recent files. *(FR-DAT-03/05/07/09/10, FR-PLT-05, Architecture §3/§6)*
- **`FileLock`:** lock file + holder metadata + heartbeat + stale-lock detection; `NSFileCoordinator`; conflict detection on write-back. *(FR-DAT-06/07/08, ADR-8)*
- **UTI/document type** registration for `.finvestlens` (`public.database`). *(FR-PLT-04)*
- **GnuCash XML importer:** gzip detect (magic `1f 8b`) + zlib; `XMLParser` SAX mappers per object (commodities, accounts, transactions/splits, prices); **preserve slots + GUIDs**; import summary; run **Scrub**. *(FR-IMP-01..08, ADR-2/ADR-4)*
- **Perf validation:** import a synthetic 100k-txn book; open/scroll/save on **local + real SMB/NFS**. *(NFR-02; §17)*

**Dependencies.** P0.
**Deliverables.** `Persistence` + `Interchange` (import half) packages; a document you can open/edit/save; GnuCash import.
**Exit criteria.** Create/open/save a document on local **and** a network share with working single-writer locking; **discard a session** leaves the on-disk file byte-unchanged; import a real `.gnucash` file with structure/GUIDs/slots intact and Scrub clean; 100k-txn perf meets NFR-02.
**Test focus.** Locking/write-back/discard (§14.4); import structural fidelity; migration.
**Risks.** PR6 (NAS write-safety, scale) — the P1 network load test is the go/no-go for GRDB direct-mode vs always-working-copy (§17).

---

## 6. Phase P2 — Core UX (accounts & register)

**Objective.** A usable app: chart of accounts and a working transaction register.

**Workstreams & tasks**
- **App shell:** SwiftUI document app; `NavigationSplitView` (macOS/iPad) / stacks (iOS); open/save/recent UI; macOS menu-bar mapping. *(FR-PLT-01, Architecture §8)*
- **Chart of accounts:** hierarchical tree + balances; create/edit/reparent/hide/delete with guards; placeholder/hidden; codes + renumber. *(FR-COA-01..06)*
- **Register/ledger:** simple + multi-split entry with live balancing; transfer/duplicate/delete/void; inline reconcile-state; reversing/jump/copy/remove-splits; whole-book journal view. *(FR-REG-01..09.)* *Built with GnuCash's three view styles; the Jul 2026 redesign replaced them with **one expandable register** + a Show All Splits option (PRD FR-REG-03), and the whole-book journal ships as **All Transactions**.*
- **QuickFill** autofill (payee/description/last-split). *(FR-REG-04)*
- **Find/search (basic)** via GRDB predicates. *(FR-REG-06 — upgraded in P4)*
- **Tags (model + minimal UI).** *(FR-TAG-01, early)*
- **Formatting/prefs:** Foundation formatters; `UserDefaults`/SwiftUI settings. *(NFR-06, replaces GSettings)*

**Dependencies.** P0, P1.
**Deliverables.** `FeatureUI` package; interactive app.
**Exit criteria.** Create accounts; enter/edit balanced (simple & split) transactions; running balances correct; search; everything persists through save/reopen.
**Test focus.** UI round-trips through the store; balancing in the editor; large-register scroll perf.
**Risks.** Register perf at 100k rows — bounded `FetchDescriptor` + cached balances (ADR-5).

---

## 7. Phase P3 — GnuCash export & round-trip

**Objective.** Write GnuCash XML that GnuCash reopens; prove round-trip fidelity.

**Workstreams & tasks**
- **Streaming XML writer:** GnuCash namespaces + exact element order; re-emit preserved slots/GUIDs; gzip + uncompressed. *(FR-EXP-01/03/04, ADR-2)*
- **Round-trip harness + corpus:** import→export→re-import; compare **object graphs** (amounts within tolerance) + order-normalized XML for structure. *(FR-EXP-02, NFR-08)*
- **Import/export UI:** menu commands, share sheet, progress.

**Dependencies.** P1 (import), P2.
**Deliverables.** `Interchange` (export half); CI round-trip gate.
**Exit criteria.** Exported file reopens cleanly in GnuCash desktop; the round-trip corpus passes in CI.
**Test focus.** Round-trip corpus; slot/GUID preservation; GnuCash-desktop reopen smoke test.
**Risks.** PR2 (slot/unknown-element loss) — compare graphs, not just re-render.

---

## 8. Phase P4 — Everyday finance, bank import & automation

> The largest phase — sequence internally as **P4a** (reconciliation, SX, budgets, core reports) → **P4b** (bank import + matcher) → **P4c** (rules, search language, bills/forecast, onboarding).

**Objective.** Daily-driver completeness: reconcile, schedule, budget, report, and import bank files with rule-driven automation.

**Workstreams & tasks**
- **A. Reconciliation** + auto-clear. *(FR-REC-01..03; ports `gnc-autoclear`)*
- **B. Scheduled transactions:** `Recurrence`, "since last run" instance model, expression parser for amounts. *(FR-SCH-01..03; ports `SchedXaction`/`Recurrence`/`gnc-sx-instance-model`/`gnc-exp-parser`)*
- **C. Core reports:** Balance Sheet, Income Statement/P&L, Net Worth, Transaction Report, Cash Flow — Swift services + Swift Charts + PDF/print. *(FR-RPT-01/03/04/05; refactor from Scheme)*
- **D. Budgets:** per-account/period; **rollover/envelope**; projected end-of-period; **auto-budget** replenish; zero-based workflow. *(FR-BUD-01/02/03, FR-PLAN-04)*
- **E. Bank file import (core):** CSV (CodableCSV + mapping profiles), QIF (custom parser), OFX/QFX (custom: v2→`XMLParser`, v1→SGML normalizer); shared **Import Matcher** (duplicate detection, account assignment). *(FR-XIO-01/02/03/05/06/08, ADR-7a; Architecture §5.8a)*
- **F. Rules engine:** rule groups; triggers (strict/non-strict); actions (category/budget/tags/notes/convert/link); stop-processing; run on create/update/import. *(FR-RULE-01; supersedes FR-PLAN-06)*. Ship a **default category taxonomy + heuristic auto-categorisation / merchant-name cleanup** on import. *(FR-RULE-03, Frollo-inspired)*
- **G. Operator search language** + saved searches; shared grammar with rule triggers. *(FR-FIND-01; upgrades FR-REG-06)*
- **H. Bill reminders + Financial Calendar + bill matching** (expected amount/range, paid/unpaid/overdue). *(FR-PLAN-01, FR-BILL-01)*
- **I. Cash-flow forecast** from scheduled bills/deposits. *(FR-PLAN-02)*
- **J. Onboarding / setup assistant** (starter chart of accounts). *(FR-PLAN-09, FR-COA-03)*

**Dependencies.** P2, P3.
**Deliverables.** Reconciliation, SX, budgets, core reports; CSV/QIF/OFX import; rules + search; bills/forecast.
**Exit criteria.** Import a bank CSV/QIF/OFX file → matcher dedupes and rules auto-categorize → reconcile against a statement → core reports render → budgets track → a scheduled transaction posts on due date.
**Test focus.** Parser conformance (vs ofxtools/Quiffen fixtures); matcher dedup; rule engine trigger/action matrix; SX recurrence vs GnuCash; report totals parity.
**Risks.** OFX v1 SGML tolerance; rule-engine scope — ship trigger/action subset first, expand.

---

## 9. Phase P5 — Investments, multi-currency & quotes

**Objective.** Full securities support with prices, lots/cap-gains, multi-currency, and live/historical quotes.

**Workstreams & tasks** — status as of completion.
- ✅ **PriceDB + Price Editor.** *(FR-ENG-09, FR-INV-02)*
- ✅ **Securities** — created with commodity (exchange/ticker/name) in the New Account editor; dedicated **Security Editor** (rename across holdings) shipped later in the backlog sweep. *(FR-INV-01/07)*
- ✅ **Lots + FIFO/LIFO/average + cap-gains + Investment Lots report.** *(FR-ENG-10, FR-INV-05)*
- ✅ **Stock Transaction Assistant** — buy/sell/dividend/reinvest/**split** (lot-rescaling)/**return-of-capital**. Commission is expensed (not capitalised). *(FR-INV-04)*
- ✅ **Multi-currency** transactions + exchange rates + FX valuation + currency-transfer entry + optional **trading accounts**. *(FR-CUR-01..04, FR-REG-07)*
- ✅ **Quote providers:** keyless Yahoo + keyed EODHD/Alpha Vantage/Finnhub; Keychain keys; latest + historical backfill; injectable transport; **scheduled auto-refresh**. *(FR-INV-03/03a–e, FR-CUR-04, ADR-7)*
- ✅ **Investment reports:** Portfolio, Advanced Portfolio (allocation donut, price-history chart), Price Scatter, Investment Lots. *(FR-RPT-02)*
- ✅ **Portfolio enhancements:** asset allocation, rate of return, **watch lists + price targets**. *(FR-PLAN-07)*
- ✅ **What-if scenarios** on cash flow (session-only hypothetical events). *(FR-PLAN-03)*
- ✅ **Rules apply-to-historical + preview** (safe recategorisation of the income/expense leg + notes). *(FR-RULE-02)*

**Dependencies.** P4.
**Deliverables.** Investments module; quote layer; investment reports.
**Exit criteria.** ✅ Record buys/sells/dividends/splits; ✅ fetch latest + historical quotes (keyless and keyed, incl. delisted via EODHD); ✅ compute cap gains via lots; ✅ value a multi-currency portfolio in a base currency.
**Status.** **Complete** — including the once-deferred Security Editor, trading accounts, scheduled quote refresh, watch lists and return-of-capital (all shipped in the functional-backlog sweep).
**Test focus.** Lot/cap-gains, cost-basis methods, splits; quote-provider parsing; FX valuation.
**Risks.** Yahoo endpoint drift (keyed providers as stable fallback); cap-gains subtlety.

---

## 10. Phase P6 — Sync, dashboard, alerts & polish

**Objective.** Ecosystem integration and the guidance layer.

**Workstreams & tasks** — status as of completion.
- ✅ **File-level sync:** `NSFilePresenter` external-change handling + a reload banner; `NSFileVersion` conflict listing/resolution; reuses the P1 SHA256 fingerprint. Storage-agnostic (local / network share / iCloud). ⏸️ Enabling an **iCloud Documents container** is a project-capability step (dev team/provisioning). *(FR-PLT-02)*
- ✅ **App Intents / Shortcuts:** Net Worth, Upcoming Bills, Financial Alerts intents + `AppShortcutsProvider` (Siri/Spotlight/Shortcuts). ⏸️ **Widgets / Quick Look** need separate extension targets — deferred (project-target work, untestable headlessly). *(FR-PLT-03)*
- ✅ **Alerts engine (Advisor-FYI):** bill-due, projected low/negative balance, over-budget, price-target; severity-ranked; KVP-persisted price targets. Surfaced on the dashboard and via the Alerts intent. ⏸️ System notifications deferred (needs UNUserNotificationCenter + entitlement). *(FR-PLAN-05)*
- ✅ **Home dashboard:** net-worth headline + 12-month trend, alerts, account balances, upcoming bills, budget status. *(FR-PLAN-08.)* *Reworked by the Jul 2026 redesign into a **non-scrolling tile board** — prioritised, content-aware cards packed into the actual window, per-user show/hide, and an Up Next action card.*
- ✅ **Accessibility pass:** VoiceOver labels/values on account rows, dashboard, alerts and every chart. ⏸️ **Localization** (string catalogs) deferred. *(NFR-05/06)*
- ✅ **Optional book lock** (Face/Touch ID via injectable `Authenticating`; Security menu; lock screen). *(NFR-07)*

**Dependencies.** P4 (bills/budgets/alerts data), P5 (portfolio for dashboard/widgets).
**Deliverables.** Sync machinery, Shortcuts, dashboard, alerts, book lock; a11y-labelled UI.
**Status.** Core **complete**. Deferred (documented in [deferred.md](deferred.md)): iCloud container enablement, widgets, Quick Look, push notifications, localization — each needs a project-capability/extension-target or entitlement step.
**Test focus.** Conflict resolution; alert rule correctness.
**Risks.** File-sync conflicts on simultaneous edits — reuses the P1 conflict-detection machinery.

---

## 11. Phase P7 — Business features

**Objective.** Small-business accounting.

**Workstreams & tasks**
- **Customers/Vendors/Employees.** *(FR-BUS-01/02; ports `gncCustomer`/`gncVendor`/`gncEmployee`)*
- **Invoices (A/R) & Bills (A/P)** posting via lots/entries. *(FR-BUS-03; ports `gncInvoice`/`gncEntry`)*
- **Jobs, Billing Terms, Tax Tables.** *(FR-BUS-04; ports `gncJob`/`gncBillTerm`/`gncTaxTable`, `libgnucash/tax`)*
- **Payments + A/R–A/P aging.** *(FR-BUS-05)*
- **Company info.** *(FR-BUS-06)*
- **Time & mileage tracking.** *(FR-PLAN-14)*
- **Import business objects** from GnuCash XML. *(FR-IMP-05)*

**Dependencies.** P4 (engine + reports patterns).
**Deliverables.** Business module; business XML import.
**Exit criteria.** Create/post an invoice and a bill, record payments, see aging; business objects round-trip through GnuCash XML.
**Test focus.** Invoice→A/R posting correctness; business object round-trip.
**Risks.** Business posting depth — port `ScrubBusiness`/lot linkage closely (PR5).

---

## 12. Phase P8 — Extended import

**Status.** ✅ **Complete (24 Jul 2026).** `MT940Importer` (SWIFT MT940/MT942 — tag-line scanner with continuation folding, `:61:` subfield grammar incl. reversals and funds codes, `:86:` narratives with German `?nn` subfield extraction) and `CAMTImporter` (streaming ISO 20022 CAMT.053/052 — signed amounts, PDNG filtering, reference/counterparty/remittance extraction across schema versions) feed `StagedTransaction` into the existing Import Matcher; `BankFileFormat.detect` adds extension mapping (`.sta`/`.940`/`.c53`/…) plus content sniffing for ambiguous `.xml`/`.txt`. Exit criterion verified in `MT940CAMTTests`: both formats through the matcher with correct dedupe (FITID and amount+window) and history-based account assignment. Preceded, same day, by an import-matcher hardening pass validated on four real bank exports (transfer completion, FITID veto, one-to-one claiming — [implemented.md](implemented.md)). (Report PDF export, once listed here as a P4 fallback, was delivered in P4. **Online bank sync was skipped by decision on 24 Jul 2026** — cloud-mediated connectors sit poorly with the app's local-first stance, and the AU CDR path carries a regulatory burden out of proportion to a file-import app; moved to [deferred.md](deferred.md) §5, revisit only on strong demand.)

**Objective.** Broader statement-file interoperability.

**Workstreams & tasks**
- ✅ **MT940/MT942 + CAMT.053 (ISO 20022)** statement import → matcher. *(FR-XIO-04)*

**Dependencies.** P4 (Import Matcher).
**Deliverables.** Bank-statement importers (SWIFT MT + ISO 20022) feeding the existing Import Matcher.
**Exit criteria.** Import a CAMT.053 and an MT940 file through the matcher with correct dedupe and account assignment. ✅
**Risks.** Format variance across banks — parse against published samples from several institutions, as the QIF/OFX parsers were.

---

## 13. Phase P9 — Planning & insights

**Status.** ✅ **Complete (24 Jul 2026).** Design and models in [planning-design.md](planning-design.md); pure calculators in `FinvestLensReports` (`DebtPlan`, `LifetimeProjection`, `TaxEstimate`, `SpendingInsights`, `WellbeingScore`) with fixture tests, the book-facing layer in `AppModel+Planning`, and the UI as a **Planner** sidebar destination (Debt Reduction / Lifetime / Tax Estimate), a **Spending Insights** report, a **Wellbeing** dashboard tile, the **Financial Summary (passport)** PDF, **savings challenges** on goals, the **Emergency Records** destination (local-authentication gate), and a GnuCash-style **audit-log sidecar** with a Tools viewer. Exit criteria verified on the real book (`LivePlanningTests`): SMSF-seeded lifetime buckets and a 51-year projection, a debt payoff plan over the live credit card, and a bracket-computed tax estimate from tagged accounts. **TXF export was consciously skipped** — a US interchange format with no meaning for an AU book; the `tax-US` code slot still round-trips for GnuCash parity ([deferred.md](deferred.md)).

**Objective.** The flagship planning layer.

**Workstreams & tasks**
- ✅ **Debt Reduction Planner** (snowball/avalanche; payoff date, interest saved). *(FR-PLAN-10)*
- ✅ **Lifetime Planner** (long-range projection: income/expenses/assets/retirement/taxes/inflation/life-events → net worth over time, goal feasibility). *(FR-PLAN-11)*
- ✅ **Tax estimator + tax-line tagging + capital-gains estimator.** *(FR-PLAN-12)*
- ✅ **Insights & comparison reports** (trends, period-vs-period, plain-language). *(FR-PLAN-13)*
- ✅ **Financial wellbeing score** (explainable) and **financial summary "passport"** PDF export. *(FR-PLAN-16/17, Frollo-inspired)*
- ✅ **Savings challenges** (gamified goals). *(FR-GOAL-02, Frollo-inspired)*
- ✅ **Emergency Records Organizer** (secure records). *(FR-PLAN-15)*
- ✅ **Audit logging.**

**Dependencies.** P5 (investments/tax data), P6 (dashboard surface).
**Deliverables.** Planners, tax tools, insights.
**Exit criteria.** Produce a debt-payoff plan and a lifetime projection from real book data; estimate tax from tagged tax lines. ✅
**Risks.** Lifetime Planner is large and assumption-heavy — ship a transparent, adjustable model; label projections clearly (not advice, per NG4).

---

## 14. Quality gates (apply every phase)

1. **Double-entry invariant** — no unbalanced transaction persists (`FR-ENG-06`). *Hard gate.*
2. **Round-trip fidelity** — import→export→re-import preserves structure/GUIDs/slots; amounts within tolerance (`FR-EXP-02`). *Hard gate from P3.*
3. **Numeric sanity (tolerant)** — `Money`/`Decimal` correctness with tolerances (ADR-1).
4. **Locking/write-back/discard** — concurrent openers, stale-lock break, mid-save crash, conflicting write, and discard/revert never corrupt or silently clobber the document (`FR-DAT-06/07/08/09`).
5. **Performance** — 100k-transaction document meets open/scroll/import/save targets (NFR-02).
6. **Accessibility** — VoiceOver + Dynamic Type on new screens (NFR-05); full audit in P6.
7. **Coverage** — engine/interchange core ≥90%; CI green on every PR.

---

## 15. Sequencing & dependency overview

```
P0 Engine ─▶ P1 Document+Import ─▶ P2 Core UX ─▶ P3 Export/round-trip
                                        │
                                        ▼
                         P4 Everyday finance + bank import + automation
                             │                 │
                             ▼                 ▼
                    P5 Investments+quotes   P7 Business
                             │                 │
                             ▼                 ▼
                    P6 Sync/dashboard/alerts   │
                             │                 │
                             ▼                 ▼
                    P9 Planning & insights   P8 Extended import
```

- **Critical path to a daily-driver release:** P0 → P1 → P2 → P3 → P4.
- P5/P7 branch off P4 and can proceed in parallel given capacity.
- P6, P8, P9 layer on the earlier phases; P9 depends on P5 (investments/tax) and P6 (dashboard).

---

## 16. Traceability

Every task cites its PRD `FR-*` (or NFR/ADR). Requirement → phase mapping is the `Phase` column of PRD §5 and the [Porting §2](porting.md) map; this plan is the inverse view (phase → tasks). The two hardest gates — round-trip fidelity (`FR-EXP-02`) and the double-entry invariant (`FR-ENG-06`) — have dedicated harnesses from P1/P3 onward.

## 17. Decision checkpoints

The architecture's open decisions and their resolutions:

| Decision | Resolution |
|---|---|
| Per-commodity rounding mode | ✅ Half-up per commodity fraction. |
| WAL vs DELETE journal for the working copy | ✅ Rollback (DELETE) journal — the write-back artifact is always one self-contained file. |
| Default quote providers shipped | ✅ Keyless Yahoo default; keyed EODHD / Alpha Vantage / Finnhub. |
| Target GnuCash XML schema version | ✅ GnuCash v5-era (`gnc:book` 2.0.0), round-trip verified against GnuCash 5.16. |
| Lock heartbeat interval & stale threshold | ✅ Periodic heartbeat + a stale threshold that offers Break-Lock; stable on provider drives. |
| GRDB direct-mode vs always-working-copy at scale | ⬜ Open — always working-copy as built; the large-book validation on real SMB/NFS is the go/no-go. Tracked in [deferred.md](deferred.md). |

## 18. References

- [PRD](prd.md) · [Architecture](architecture.md) · [Porting Strategy](porting.md) · [Money study](enhancements-msmoney.md) · [Firefly study](enhancements-firefly.md) · [Frollo study](enhancements-frollo.md) · [README](../README.md)
