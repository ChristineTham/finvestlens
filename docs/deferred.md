# Deferred backlog — open issues & gaps

Everything still **open**. Phases **P0–P7 are complete**; what remains is
**P8** (extended import / bank sync), **P9** (planning & insights), a set of
cross-cutting infrastructure items, and a handful of small tails within the
completed phases. Anything already built and verified lives in
[implemented.md](implemented.md); intentional non-goals (e.g. bit-for-bit
arithmetic parity with GnuCash) are not listed anywhere.

Each row cites its PRD `FR-*` and a suggested pick-up phase.

Companions: [Plan](plan.md) · [PRD](prd.md) · [Architecture](architecture.md) ·
[Implemented](implemented.md).

---

## Cross-cutting infrastructure

Not phase features — engineering and platform enablement that spans releases.

| Item | Origin | Status | Notes | Target |
|---|---|---|---|---|
| CI pipeline + file-header/coverage gate | P0 (NFR) | absent | Tests run locally; no `.github`. | P8 |
| Round-trip corpus CI gate | P3 | partial | Interop verified manually via `gnucash-cli` and the env-gated `LiveFileRoundTripTests`; the automated CI gate is pending. | P8 |
| 100k-txn perf validation (local + SMB/NFS) | P1 (NFR-02, OD-1/2/3) | not-run | Go/no-go for GRDB direct-mode vs working-copy on a network share. | P8 |
| iCloud Documents container | P6 (FR-PLT-02) | needs-capability | Sync machinery done + storage-agnostic; enabling the container needs a dev team / provisioning. | P8+ |
| Widgets | P6 (FR-PLT-03) | needs-target | WidgetKit extension target; `IntentSupport` summaries ready to feed it. | P8+ |
| Quick Look preview | P6 (FR-PLT-03) | needs-target | Quick Look extension target. | P8+ |
| Push notifications for alerts | P6 (FR-PLAN-05) | needs-entitlement | Alerts engine + dashboard done; `UNUserNotificationCenter` delivery pending. | P8+ |
| Localization (string catalogs) | P6 (NFR-06) | absent | Accessibility labels done; UI strings not yet localized. | P8+ |
| Business/budget/scheduled in native GnuCash XML slots | P3/P7 (FR-IMP-03/05) | partial | Persisted as KVP-JSON in our own slots and round-tripped; not written as GnuCash's own `sx:`/budget/business XML slots (GnuCash import counts them as warnings). | P8 |

## Completed-phase tails (P0–P7)

Small open items inside phases that are otherwise done.

| Item | FR | Notes | Target |
|---|---|---|---|
| Business: Bills Due Reminder surface | FR-BUS-05 | `aging`/`agingByOwner` give the data; the reminder UI is todo. | P7 tail |
| Business: vendor / employee / job detail reports | FR-BUS | Customer Summary + aging built; the per-owner detail reports are todo. | P7 tail |
| Business: Australian-Tax invoice layout | FR-BUS-03 | Printable/Tax invoice PDF built; the AU-specific layout is todo. | P7 tail |
| Business: time & mileage tracking | FR-PLAN-14 | Not implemented. | P7 tail |
| Legacy report internals → document scaffold + PDF | FR-RPT-05 | Transactions, Reconciliation, Forecast, Portfolio, Investment Lots, Price Scatter, Capital Gains keep their interactive views; migrating them onto `ReportDocument` (and giving each PDF export) is follow-up. | P8 |
| Advanced Portfolio extra columns | FR-RPT-02 | Money In/Out, Income, Rate-of-Return columns. | P8 |
| Managed-fund money-flow realised model | FR-RPT-02 | Our per-parcel engine subtracts non-fee expense splits booked inside managed-fund transactions where GnuCash's money-in/out model washes them out (~$34k realised across ~6 accounts). Matching would mean adopting GnuCash's money-flow realised model — arguably not more correct. | P8 |
| `rebuildAccountTree` subtree-only rebuild | FR-DOC-01 | The remaining ~0.04s of every `refreshAll()` is a full-tree rebuild + `runSearch`; fast enough to feel instant. Rebuild only the affected subtree if ever needed. | P8 |
| Open Read-Only on a live lock | §6.1 | Open fails with holder info + Break-Lock; no read-only mode. | P8 |
| Autosave interval setting | §3 | Fixed 5 min; not user-configurable/disableable yet. | P8 |
| Manual attach from the transaction editor | FR-REG-10 | Smart Import links applied PDFs (`assoc_uri`) and the register opens them; a manual "attach a file to this transaction" action is not offered. | P8 |

## P8 — Extended import & bank sync

| Item | FR | Notes |
|---|---|---|
| QIF splits + investment actions | FR-XIO-01 | Parser handles flat D/T/U/P/M/N/L cash rows; `S/E/$` splits and `!Type:Invst` actions dropped. |
| OFX investment statements | FR-XIO-02 | Only `<STMTTRN>` cash rows parsed; `<INVBUY>`/`<INVSELL>` ignored (use the Stock Assistant). |
| CSV price import | FR-XIO-03 | CSV imports transactions only. |
| CSV export | FR-XIO-06 | No CSV export (GnuCash XML export covers interchange). |
| CSV mapping profiles | FR-XIO-08 | Column mapping is per-import; no saved profiles. |
| MT940 / MT942 + CAMT.053 (ISO 20022) | FR-XIO-04 | Bank-statement importers → matcher. |
| Online bank sync | FR-XIO-07 | SimpleFIN / GoCardless (Nordigen); for AU the CDR (Open Banking) via an accredited intermediary. Optional, consented, cloud-mediated; app stays functional offline. CDR needs regulatory diligence. |
| Twelve Data quote provider | FR-INV-03b | Yahoo / EODHD / Alpha Vantage / Finnhub shipped; Twelve Data / Stooq not. |
| Re-open a finished reconciliation | FR-REC-03 | Begin/toggle/finish/cancel only. |
| Scanned-statement OCR quality | FR-AI-01 | Vision OCR fallback untested against real bank scans; digital-PDF reflow is solid. |
| Statement sign inference without a balance column | FR-AI-01 | Signs re-derived from the running balance; statements with unsigned debit/credit columns *and* no balance column may import with wrong signs (the review screen catches it). |
| Smart Import: create a transaction from an unmatched invoice | FR-AI-07 | An invoice with no matching register transaction reports "import the bank statement first"; direct creation (with a funding-account picker) is not offered. |
| iOS file pickers on-device | FR-AI-01/03/04/07 | iOS keeps `.fileImporter`; not yet exercised on a device. |

## P9 — Planning & insights

| Item | FR | Notes |
|---|---|---|
| Debt Reduction Planner | FR-PLAN-10 | Snowball / avalanche; payoff date, interest saved. |
| Lifetime Planner | FR-PLAN-11 | Long-range projection: income/expenses/assets/retirement/taxes/inflation/life-events → net worth over time. Large and assumption-heavy; ship a transparent, adjustable, clearly-labelled model. |
| Tax estimator + capital-gains estimator | FR-PLAN-12 | Tax-line *tagging* now exists (Tax Report Options); the estimator and TXF export do not. |
| Tax Schedule Report / TXF export | FR-PLAN-12 | Accounts can be tax-flagged with a code; the schedule report and TXF-file export are todo. |
| Insights & comparison reports | FR-PLAN-13 | Trends, period-vs-period, plain-language. |
| Financial wellbeing score + "passport" PDF | FR-PLAN-16/17 | Explainable score; shareable financial-summary PDF (Frollo-inspired). |
| Savings goals / piggy banks | FR-GOAL-01 | Not implemented. |
| Savings challenges | FR-GOAL-02 | Gamified goals (Frollo-inspired). |
| Loan amortization assistant | FR-SCH-04 | The Loan **Calculator** is built (payment + schedule); the *assistant* that creates the scheduled loan transactions is not. |
| Scheduled-split formulas | FR-SCH-02 | Fixed amounts only (the amount-expression parser is built for entry; per-split SX formulas are not). |
| Check printing | FR-REG-11 | Not implemented. |
| Emergency Records Organizer | FR-PLAN-15 | Secure records store. |
| Audit logging | — | Not implemented. |

## Platform & HIG — deferred decisions

| Item | Notes |
|---|---|
| App Sandbox | Disabled by decision (13 Jul 2026): sibling `.lock` files at user-selected locations are denied by the sandbox; related-item declaration + coordinated I/O are in place but macOS still refused. Direct (notarized) distribution doesn't need it. Revisit before any Mac App Store submission. |
| iOS move/rename flow for new books | New books land in the app's Documents directory with safe naming; an in-app move/rename flow is todo. |
| Esc inside a focused text field | AppKit's field editor consumes the raw Escape (completion); ⌘. always cancels, Esc works otherwise. SwiftUI offers no clean override. |
| Window / state restoration | The app launches to the splash; it does not reopen the last book automatically. |
| Help menu | No help book / anchors. |

## Known model divergences (accepted)

Documented in [implemented.md](implemented.md) as non-gaps, repeated here so they
aren't re-discovered as bugs: currency-commodity export emits `cmdty:fraction`/
`name` GnuCash omits for ISO currencies (within FR-EXP-02 tolerance, round-trip
byte-verified); `isBalanced` treats a sub-minor-unit residual as balanced (ADR-1);
average-cost basis keeps full precision to the report edge where GnuCash rounds
progressively (~2¢ over 40 years, wontfix).
