# Deferred backlog — open items within P0–P7

Work that was **in scope for the delivered phases (P0–P7)** but is still open:
deferred, partial, or not yet built. It is **ranked** — highest priority /
readiest to pick up first.

Out of scope for this list: the future phases **P8** (extended import / bank
sync) and **P9** (planning & insights), which are planned, not deferred — see
[plan.md](plan.md). Anything already built is in [implemented.md](implemented.md);
intentional non-goals (e.g. bit-for-bit arithmetic parity with GnuCash) are not
tracked anywhere.

Each row cites its PRD `FR-*`/`NFR-*` and the phase it belonged to.

Companions: [Plan](plan.md) · [PRD](prd.md) · [Implemented](implemented.md).

---

## 1 — Release readiness (do first)

Quality automation and validation that a shippable release needs.

| Item | FR / Phase | Notes |
|---|---|---|
| CI pipeline + round-trip corpus gate | NFR-08 / P0, P3 | Tests run locally; no `.github`. The env-gated `LiveFileRoundTripTests` and `gnucash-cli` interop are run by hand — automate them (and a file-header/coverage gate) as the CI gate. |
| Large-book perf validation (local + SMB/NFS) | NFR-02 / P1 | Open/scroll/import/save on a 100k-txn book over real SMB/NFS. Also settles the one open architecture decision: GRDB **direct-mode vs always-working-copy** on local volumes (Architecture §10). |
| Localization (string catalogs) | NFR-06 / P6 | Accessibility labels done; UI strings not yet localized. |

## 2 — User-facing gaps (high value, tractable)

Common workflows partly built; each is a bounded piece of work.

| Item | FR / Phase | Notes |
|---|---|---|
| CSV export (accounts / transactions / prices) | FR-XIO-06 / P4 | No CSV export yet (GnuCash XML export covers interchange). |
| CSV price import | FR-XIO-03 / P4 | CSV imports transactions only. |
| CSV mapping profiles | FR-XIO-08 / P4 | Column mapping is per-import; no saved profiles. |
| QIF splits + investment actions | FR-XIO-01 / P4 | Parser handles flat D/T/U/P/M/N/L cash rows; `S/E/$` splits and `!Type:Invst` actions dropped. |
| OFX investment statements | FR-XIO-02 / P4 | Only `<STMTTRN>` cash rows parsed; `<INVBUY>`/`<INVSELL>` ignored (use the Stock Assistant). |
| Re-open a finished reconciliation | FR-REC-03 / P4 | Begin/toggle/finish/cancel only. |
| Manual attach a file to a transaction | FR-REG-10 / P6 | Smart Import links applied PDFs (`assoc_uri`) and the register opens them; a manual "attach a file" action from the editor is not offered. |
| Twelve Data quote provider | FR-INV-03b / P5 | Yahoo / EODHD / Alpha Vantage / Finnhub shipped (`QuoteProviderKind` has 4 cases); Twelve Data / Stooq not. |
| Import scheduled transactions from a GnuCash file | FR-IMP-03 / P4 | FinvestLens's own scheduled transactions work, but `<gnc:schedxaction>` in an imported GnuCash file is silently dropped (`GnuCashXMLImporter` `default: break`) — not even counted as a warning. |
| Import budgets from a GnuCash file | FR-IMP-04 / P4 | `<gnc:budget>` in an imported GnuCash file is silently dropped, as above. In-app budgets work. |
| Rule actions beyond category + notes | FR-RULE-01 / P4 | Rule actions are limited to set-account and set-notes; FR-RULE-01's set-tags, set-description, convert-type, link-to-bill and allocate-to-goal are not built, and triggers test only description / memo / amount. |
| Open Read-Only on a live lock | FR-DAT-06 / P1 | Open fails with holder info + Break-Lock; no read-only mode. |
| Autosave interval setting | FR-DAT-10 / P2 | Fixed 5-minute interval (`AppModel` hardcoded 300 s); not user-configurable/disableable, no Settings control. |

## 3 — Platform enablement (needs a target / entitlement)

Mechanical once the extension target or capability is provisioned; the feeding logic exists.

| Item | FR / Phase | Notes |
|---|---|---|
| iCloud Documents container | FR-PLT-02 / P6 | Sync machinery done + storage-agnostic; enabling the container needs a dev-team provisioning step. |
| Widgets | FR-PLT-03 / P6 | WidgetKit extension target; `IntentSupport` summaries ready to feed it. |
| Quick Look preview | FR-PLT-03 / P6 | Quick Look extension target. |
| Push notifications for alerts | FR-PLAN-05 / P6 | Alerts engine + dashboard done; `UNUserNotificationCenter` delivery pending. |

## 4 — Feature tails within delivered phases

Lower-priority pieces of features that are otherwise complete.

| Item | FR / Phase | Notes |
|---|---|---|
| Legacy report internals → document scaffold + PDF | FR-RPT-05 / P4 | Transactions, Reconciliation, Forecast, Portfolio, Investment Lots, Price Scatter, Capital Gains keep their interactive views; migrating them onto `ReportDocument` (and giving each PDF export) is follow-up. |
| Scheduled-split formulas | FR-SCH-02 / P4 | Fixed amounts only (the amount-expression parser is built for entry; per-split SX formulas are not). |
| Check printing | FR-REG-11 / P4 | Not implemented. |
| Savings goals / piggy banks | FR-GOAL-01 / P5 | Not implemented. |
| Loan amortization assistant | FR-SCH-04 / P5 | The Loan **Calculator** exists (payment + schedule); the *assistant* that generates the scheduled loan transactions does not. |
| Advanced Portfolio extra columns | FR-RPT-02 / P5 | Money In/Out, Income, Rate-of-Return columns. |
| Managed-fund money-flow realised model | FR-RPT-02 / P5 | Our per-parcel engine subtracts non-fee expense splits booked inside managed-fund transactions where GnuCash's money-in/out model washes them out (~$34k realised across ~6 accounts). Matching would mean adopting GnuCash's money-flow model — arguably not more correct. |
| Business: vendor / employee / job detail reports | FR-BUS / P7 | Customer Summary + Receivable/Payable Aging built; the per-vendor/employee/job detail reports are todo. |
| Business: Australian-Tax invoice layout | FR-BUS-03 / P7 | Printable INVOICE/BILL/VOUCHER PDF built (with an ABN/Tax-ID field on company info); a "Tax Invoice"-titled AU GST layout is todo. |
| Business: time & mileage tracking | FR-PLAN-14 / P7 | Not implemented (no billable-time / mileage model). |
| Free-text search operator coverage | FR-FIND-01 / P4 | The free-text box supports `tag:`/`account:`/`memo:`/`desc:`/`amount:` (with `>`/`<`) and saved searches; the documented `from:`/`to:`/`type:`, relative `d/w/m/y` date offsets, and `-` negation are only in the structured Find (⌘F) dialog, not the token grammar. |
| `rebuildAccountTree` subtree-only rebuild | NFR-02 / P2 | The remaining ~0.04s of a refresh is a full-tree rebuild + search; fast enough to feel instant. Rebuild only the affected subtree if ever needed. |

## 5 — Apple Intelligence import caveats (monitor)

Quality limits of the on-device import layer (PRD §5.18), caught by the review screen.

| Item | FR / Phase | Notes |
|---|---|---|
| Scanned-statement OCR quality | FR-AI-01 / P4 | Vision OCR fallback untested against real bank scans; digital-PDF reflow is solid. |
| Statement sign inference without a balance column | FR-AI-01 / P4 | Signs re-derived from the running balance; statements with unsigned debit/credit columns *and* no balance column may import with wrong signs (the review screen catches it). |
| Smart Import: create a transaction from an unmatched invoice | FR-AI-07 / P7 | An invoice with no matching register transaction reports "import the bank statement first"; direct creation (with a funding-account picker) is not offered. |
| iOS file pickers on-device | FR-AI-01/03/04/07 / P4–P7 | iOS keeps `.fileImporter`; not yet exercised on a device. |

## 6 — Platform & HIG — deferred decisions

| Item | Notes |
|---|---|
| App Sandbox | Disabled by decision: sibling `.lock` files at user-selected locations are denied by the sandbox; related-item declaration + coordinated I/O are in place but macOS still refused. Direct (notarized) distribution doesn't need it. Revisit before any Mac App Store submission. |
| iOS move/rename flow for new books | New books land in the app's Documents directory with safe naming; an in-app move/rename flow is todo. |
| Esc inside a focused text field | AppKit's field editor consumes the raw Escape (completion); ⌘. always cancels, Esc works otherwise. SwiftUI offers no clean override. |
| Window / state restoration | The app launches to the splash; it does not reopen the last book automatically. |
| Help menu | No help book / anchors. |

---

## Accepted divergences (won't-fix)

Not open work — recorded so they aren't re-raised as bugs. Detail in
[implemented.md](implemented.md).

- Currency-commodity export emits `cmdty:fraction`/`name` that GnuCash omits for
  ISO currencies — within FR-EXP-02 tolerance, round-trip byte-verified.
- `isBalanced` treats a sub-minor-unit residual as balanced (ADR-1).
- Average-cost basis keeps full precision to the report edge where GnuCash rounds
  progressively (~2¢ over 40 years).
