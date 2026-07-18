# Implemented — history, audits & fixes (P0–P7)

The record of what has been **built and verified**. Phases P0–P7 are complete:
the engine, native document + NAS locking, GnuCash import/export, core UX,
everyday finance, investments + multi-currency + quotes, sync/dashboard/alerts,
Apple Intelligence, and small-business features. Only **P8** (extended import /
bank sync) and **P9** (planning & insights) remain — tracked in
[deferred.md](deferred.md), which also lists the smaller open tails within
P0–P7.

This file is the narrative: what each audit found, what was fixed, and how it
was verified (mostly against a real GnuCash book — 46,553 transactions, 559
accounts, 102,706 prices, multi-currency — compared side by side with GnuCash
5.16, matching to the cent). New history is appended here; open work goes to
deferred.md.

Companions: [PRD](prd.md) · [Architecture](architecture.md) · [Plan](plan.md) ·
[Deferred](deferred.md).

---

## Deferred-backlog closeout (18 Jul 2026)

Resolved a batch of open P0–P7 items from deferred.md, each with tests and a
GnuCash-source reference where relevant:

- **CSV export** (FR-XIO-06) — `CSVExporter` for the account tree, transactions
  (one row per split, GnuCash's "full" layout) and prices; columns mirror
  GnuCash's `csv-tree-export` / `csv-transactions-export`. File ▸ Export CSV.
- **CSV price import** (FR-XIO-03) — `CSVPriceImporter` (explicit mapping or
  header autodetection); `AppModel.importPrices` resolves symbols against the
  book's commodities. Import CSV in the Prices panel.
- **Import GnuCash scheduled transactions + budgets** (FR-IMP-03/04) — a
  second-pass parser (`GnuCashScheduledBudgetImport`) maps `<gnc:schedxaction>`
  (recurrence, template splits via the sched-xaction slot) and `<gnc:budget>`
  (per-period amounts) into the `finvestlens/*` KVP slots the app reads.
  Verified against the real Ashley Bears book (2 SX + 1 budget); live
  round-trip stays byte-clean.
- **Twelve Data + Stooq quote providers** (FR-INV-03b) — one keyed JSON, one
  keyless CSV fallback; surfaced via `QuoteProviderKind.allCases`.
- **Re-open a finished reconciliation** (FR-REC-03) — reverts the last
  statement's reconciled splits to cleared.
- **Manual attach-a-file** (FR-REG-10) — Transaction ▸ Attach File… over the
  existing `assoc_uri` document-link machinery.
- **Open Read-Only on a live lock** (FR-DAT-06) — `openReadOnly` reads without
  taking the lock; edits refused at the `editing`/`editingWholeBook`
  chokepoints; save throws. Offered on the locked-open alert.
- **Autosave-interval setting** (FR-DAT-10) — Off/1/5/10/15 min in a new General
  settings tab; the loop re-reads it live.
- **Free-text search operators** (FR-FIND-01) — `from:`/`to:` (incl. relative
  `-7d`/`-2w`/`-3m`/`-1y`), `type:`, `category:`, `has:`, and `-` negation added
  to the token grammar.
- **Window/state restoration** — reopen the last book on launch (General
  setting).
- **Help menu** — a FinvestLens Help item (⌘?) opening an in-app
  getting-started + search-grammar + keyboard-shortcut reference.
- **CSV import mapping profiles** (FR-XIO-08) — named column-mapping profiles
  (Load / Save as Profile… / Delete) persisted app-wide for repeat imports.
- **Rules: `account` trigger + set-tags / set-description actions**
  (FR-RULE-01, partial) — engine + apply-to-history + editor UI; convert-type /
  link-to-bill / allocate-to-goal still need bill/goal infra.
- **Advanced Portfolio: Money In / Money Out / Income / rate-of-return columns**
  (FR-RPT-02) — from the lot engine's proceeds/cost-basis, plus an **Income**
  column: cash dividends/interest attributed by summing income-account splits in
  every transaction that touches the security account (GnuCash's
  `advanced-portfolio.scm` money-in model), FX-converted on the posting date and
  deduped per transaction. Income folds into total return over money-in.
- **Scheduled-split formulas with variables** (FR-SCH-02) — a `ScheduledSplit`
  can carry a GnuCash credit/debit **formula** (e.g. `interest`, `pay - interest`)
  instead of a fixed amount; `AmountExpression` evaluates it against named
  variables prompted at post time. Imported from GnuCash's SX formula slots and
  surfaced in the Add-Scheduled sheet + the Enter-Due-Transactions prompt.
- **Rules: allocate-to-goal action** (FR-RULE-01) — a rule can now earmark a
  matched transaction's amount to a savings goal (`FR-GOAL-01`); Apply-to-History
  previews the allocation and commits the aggregated goal deltas as one change.
  Leaves only convert-type and link-to-bill on the rules-action tail.
- **Smart Import: create a transaction from an unmatched invoice** (FR-AI-07) —
  when an analysed invoice has no matching register transaction, the review row
  now offers *Create Transaction…* with a funding-account picker (bank / cash /
  asset / credit / liability). The new transaction pays the total from that
  account, split across each line item's suggested category (line-sum residual
  posted as an adjustment), and the PDF is linked to it.
- **Savings goals / piggy banks** (FR-GOAL-01) — named targets that earmark part
  of an asset account (Firefly III's piggy banks): target amount + optional date
  + group, add/withdraw money (a read-model, no transaction posted), progress
  bars, and completion. Book-menu Savings Goals panel; stored as one JSON
  collection in a book KVP slot (`finvestlens/savingsGoals`), so each change is
  one undoable whole-book edit and it round-trips through save/reload.
- **Check printing** (FR-REG-11) — Transaction ▸ Print Check… draws a check
  for the selected transaction: the outflow from a bank/cash/asset account sets
  the amount and the account, the description is the payee, and the amount is
  spelled out on the legal line (`AmountInWords`, GnuCash's `numeric_to_words`).
  Rendered in the conventional US personal-check layout and saved as a PDF.
- **Business: Australian Tax Invoice layout** (FR-BUS-03) — a second printable
  layout on the invoice PDF (GnuCash `taxinvoice.scm`): the ATO-required "Tax
  Invoice" title, the seller's **ABN** in the header, a per-line **GST Rate**
  column, GST-labelled totals (Subtotal excl GST / GST / Total inc GST), and the
  "Total price includes GST of $X" statement. Chosen from the invoice's
  Save PDF… menu alongside the standard layout.
- **Business: Vendor / Employee / Job summary reports** (FR-BUS) — three new
  business reports joining Customer Summary + Receivable/Payable Aging, one row
  per party (charged / paid / outstanding over its posted documents, most-charged
  first), the shared shape behind GnuCash's per-owner reports. Book-wide, as-of,
  PDF-exportable through the report scaffold.
- **Loan amortization assistant** (FR-SCH-04) — `LoanCalculator.scheduledPayment`
  builds a GnuCash Mortgage/Loan-style scheduled transaction: fixed payment out
  of the funding account, split into a variable **interest** leg (`FR-SCH-02`
  formula, read from the schedule) and the remaining **principal**. Wired into
  the Loan Calculator view via a "Create Scheduled Payment…" sheet that picks the
  three accounts.
- **CI** (NFR-08) — `.github/workflows/ci.yml`: a matrix job builds + tests the
  seven core packages and an SPDX-header gate on every push/PR; the app +
  Intelligence build job is present but `continue-on-error` until a hosted
  macOS-26 / Xcode-26 runner exists.

Every code item above ships with unit tests (or, for the GnuCash SX/budget
import, a real-book verification); each package suite and the full app build
(`CODE_SIGNING_ALLOWED=NO`) are green. The remaining deferred items are either
larger features (QIF/OFX investment import, savings goals, report→PDF
scaffold) or
externally blocked (Apple developer-portal provisioning, real NAS/SMB
hardware, a physical iOS device, human translators) — see deferred.md.

## Platform enablement — extension targets & capabilities (18 Jul 2026)

Closed the deferred.md §3 "needs a target / entitlement" gaps: the targets,
entitlements, and feeding code, then **provisioned, signed and verified working**
end-to-end (iCloud, App Group, both extensions) under team *Hello Tham Pty. Ltd.*
(`RPL5R637DS`).

**Bundle-ID change.** `com.hellotham.finvestlens` turned out to be held by an
inaccessible Apple team, so its explicit App ID (which capabilities require)
couldn't be registered — signing failed the moment entitlements were added. The
app's identity moved to `com.hellotham.finvestlensapp` (extensions become
`…finvestlensapp.FinvestLensWidgets` / `.FinvestLensQuickLook`, App Group
`group.com.hellotham.finvestlensapp`, iCloud `iCloud.com.hellotham.finvestlensapp`);
the **`.finvestlens` file extension / document UTI is unchanged**. Provisioning
was staged (app capabilities first, then the two extension targets) to isolate
signing risk. Steps captured in [provisioning.md](provisioning.md).

- **App entitlements** — new `finvestlens.entitlements` (wired via
  `CODE_SIGN_ENTITLEMENTS` on both app configs): the App Group
  `group.com.hellotham.finvestlensapp` and the iCloud CloudDocuments container
  `iCloud.com.hellotham.finvestlensapp` (FR-PLT-02). `Info.plist` gained
  `NSUbiquitousContainers` so the book surfaces as a "FinvestLens" folder in
  iCloud Drive. App Sandbox stays off (the sibling `.lock` needs it off).
- **FinvestLensShared** — a Foundation-only leaf package: the App Group helper
  (`SharedAppGroup`) + the `WidgetSnapshot` the app publishes for its
  extensions. Deliberately dependency-free so a memory-limited extension links
  it without pulling Engine/GRDB/SwiftUI. Unit-tested.
- **Snapshot pipeline** — `AppModel.publishWidgetData()` builds the snapshot
  from the **live in-memory book** (never re-reading the 56 MB document) on
  save / open / close, writes it to the App Group container, and reloads widget
  timelines. `IntentSupport.snapshot()` does the same out-of-process (for
  intents) by reading the last book.
- **FinvestLensWidgets** — a WidgetKit app-extension target with Net Worth and
  Alerts widgets (small/medium), reading only the snapshot (FR-PLT-03).
- **FinvestLensQuickLook** — a Quick Look preview extension: a
  `QLPreviewingController` that reads the previewed `.finvestlens` file with
  read-only system SQLite3 (no GRDB) and shows headline counts (accounts /
  transactions / commodities / prices) (FR-PLT-03).
- **Local notifications** — `AlertNotificationScheduler` delivers the alerts
  engine as `UNUserNotificationCenter` local notifications (FR-PLAN-05), deduped
  by each alert's stable id, warning/critical only; authorization requested once
  at launch. (Remote/APNs push stays a non-goal — FinvestLens is local-first,
  with no server to originate a push.)

The two extension targets were registered in the modern (objectVersion-77,
synchronized-group) `project.pbxproj` by scripted, cross-referenced insertion;
each step was validated with `plutil -lint` + `xcodebuild -list`, and the app
scheme builds and embeds both `.appex` bundles
(`xcodebuild … CODE_SIGNING_ALLOWED=NO`). The `FinvestLensShared` package is
`swift build`/`swift test` green.

## Release 1.0 (P0–P6)

The engine, native `.finvestlens` document + locking, GnuCash import/export,
core UX, everyday finance (reconcile / scheduled / budgets / reports / bank
import / rules / search), investments + multi-currency + quotes, and
sync / dashboard / alerts / lock — with undo/redo, save-on-quit, and a full
menu bar after the usability + HIG passes. Shipped 13 July 2026.

## Functional deficits resolved (P2–P5)

Items that were in scope for a completed phase but were initially deferred or
partial, since implemented:

| Item | FR | Origin |
|---|---|---|
| Tags (model + editor + `tag:` search) | FR-TAG-01 | P2 |
| Operator search language | FR-FIND-01 | P4 |
| Account codes + renumber | FR-COA | P2 |
| Register styles (journal / general ledger) | FR-REG-01 | P2 |
| Transaction Report | FR-RPT-04 | P4 |
| Report PDF export | FR-RPT | P4 |
| Saved searches | FR-FIND-01 | P4 |
| Merchant cleanup + heuristic categorisation | FR-RULE-03 | P4 |
| Default taxonomy / starter chart | FR-COA-03 | P4 |
| Onboarding assistant | FR-PLAN-09 | P4 |
| Bill reminders + Financial Calendar + matching | FR-PLAN-01, FR-BILL-01 | P4 |
| Budget rollover / envelope | FR-BUD-02 | P4 |
| Auto-budget replenish / zero-based | FR-BUD-03, FR-PLAN-04 | P4 |
| Return-of-capital action | FR-INV-04 | P5 |
| Investment Lots + Price Scatter + rate of return | FR-RPT-02 | P5 |
| Stock splits | FR-INV-04 | P5 |
| Security Editor | FR-INV-07 | P5 |
| Watch lists | FR-PLAN-07 | P5 |
| Trading accounts (multi-currency FX balancing) | FR-CUR, FR-REG-07 | P5 |
| Scheduled quote auto-refresh | FR-INV-03 | P5 |
| Rules apply-to-historical + preview | FR-RULE-02 | P5 |
| What-if scenarios on cash flow | FR-PLAN-03 | P5 |
| UTI / document-type registration | FR-PLT-04 | P1 |

## GnuCash round-trip fidelity (14 Jul 2026)

Deep round-trip on a real 8.5 MB book (560 accounts, 46,578 txns, 102,706
prices) is **clean** — full graph + balances identical, double export
byte-identical. Found & fixed: template-transactions ROOT hijacked the book
(orphaning every real account); price/amount precision loss (exporter rounded
to currency SCU; now exact rationals with continued-fraction recovery for FX
cross-rates); book GUID not re-imported. Re-runnable harness:
`FL_ROUNDTRIP_FILE=… swift test --filter LiveFileRoundTripTests`.

**KVP (slot) fidelity.** All slots on book/account/transaction/split are
preserved verbatim through import/export (nested frames, lists, gdate/timespec,
guid, numeric, integer); `notes` is lifted into `Account.notes`/
`Transaction.notes`. Verified on the real book (18,646 notes, 3,944 online_id,
colours, reconcile-info) — round-trip clean including KVP equality.

**Commodity fidelity.** `Commodity` gained `exchangeCode` / `getQuotes` /
`quoteSource` / `quoteTimezone` / `kvp` (identity stays namespace+mnemonic;
backward-compatible Codable + sqlite v2 migration), so `cmdty:xcode`, quote
config, and `cmdty:slots` (`user_symbol`) round-trip. The live harness compares
the export against the **original** file's inventory (slot-key multiset, entity
+ cmdty element counts) — clean on the real book.

**Check & Repair** (offered after import and in the Book menu) removes empty
transactions, houses orphan splits, and posts imbalances — so exports are
cleaner than the source. GnuCash **account colours** render as Finder-tag-style
dots in the sidebar and are editable with a native colour picker.

## GnuCash parity audit — accounts & transactions (15 Jul 2026)

Audited the register and account functions against a real GnuCash 5.x running
the same book, menu by menu. Three **bugs** came out and are fixed
(`EditFidelityTests` pins each; every one was verified to fail with its fix
reverted):

| Bug | Was | Now |
|---|---|---|
| Editing a transaction destroyed share counts and split memos | `EditableSplit` carried only account + amount, so `commit()` rebuilt every split with `quantity: nil` (→ defaults to value) and `memo: ""`. Re-saving an unchanged 100-share/$1,000 buy left **1000 shares**, memo gone. Balance checks can't see it: the *values* still balance. | The editor row carries `quantity`/`memo` through untouched; `asInput` is the single exit point. Verified in the GUI: the 11,600-share AGL buy re-saves with 11,600 shares and Net Worth unmoved. |
| Voided splits still moved the register's running balance | `Book.balance` excludes voided (`Book.matches`), `refreshRegister` did not — so the register's last balance disagreed with the sidebar and every report. | The row still shows with its amount and `v`; it no longer moves the balance. |
| No Unvoid, and the R column silently un-voided | `cycleReconcileState`'s `default` mapped voided → `n`, one split at a time. | `unvoidTransaction`/`isVoided` added (context menu shows Void or Unvoid); the cycle leaves voided **and** frozen alone. |

A note on auditing: five rows of the original gap list were wrong, all
overstating the gap (a hidden-account toggle that existed, an account-tree
filter already written for Find, Journal-style Edit that was present, etc.).
The lesson: a row here is a claim about code and ages like one.

**Data-integrity bug found while auditing (15 Jul 2026):**

| Bug | Was | Now |
|---|---|---|
| Editing a transaction silently un-reconciled it | `updateTransaction` rebuilt every split from `SplitInput`, which carried only account, value, quantity and memo. Everything else came back as a constructor default: `reconcileState` reset to `n`, `reconcileDate`/KVP dropped, `action` lost, the split's guid regenerated. Retyping a description was enough. 34,939 of 46,553 transactions have a reconciled/cleared split, so the status-bar Reconciled balance — $57,909.82, matching GnuCash to the cent — would have walked down as transactions were edited. The values still balanced, so nothing downstream could see it. | The save re-attaches to the split each row came from, keyed by a `splitID` the row carries; what the editor never showed survives because it is never copied. The save also stopped assigning `dateEntered = datePosted` on every edit. |

**Parity gaps found and since built** (all `done`; verified against GnuCash's
own figures where possible):

- **Structured Find (⌘F)** — GnuCash's Split Search: 14 of 16 criteria, all/any,
  add/remove rows. A criterion tests a *split*, not a transaction; results roll
  up to one row per transaction but keep the matched split. Verified: 5,385
  reconciled CDIA splits totalling **$57,909.82**, GnuCash's own status-bar
  figure, to the cent. Account picker is a filterable collapsed tree (GnuCash's
  "Select Accounts to Match"); Closing Entries + All Accounts criteria;
  new/refine/add/delete search types replayed as a live pipeline; saved queries
  in book KVP (which GnuCash cannot do).
- **Search results are actionable** — select, Edit-in-place, Show in Register
  (opens the balance-sheet leg, not `Imbalance-*`), and multi-select bulk
  actions (set reconcile state / void / delete, each one edit + one Undo).
- **Find Account (⌘I)** — type, Return; shares the `matching` predicate with Find
  and the sidebar filter. Import Bank File moved to ⌥⌘I.
- **Register Sort By / Filter By** — Sort menu (Standard/Date/Entry/Number/
  Amount/Description/Memo + reverse) and Filter sheet (date range + 5 reconcile
  statuses), mirroring GnuCash's View menu, persisted per account in
  UserDefaults, click-to-sort headers. The balance is computed once in canonical
  order, then filtered, then sorted (both display-only). Verified on CDIA
  against GnuCash: identical rows, order and balances (238,358.52 → 294,057.07).
- **Double-line mode** — editor Notes field, per-split memo + action, and View ▸
  Double Line joining notes · memo · action under the description. 18,641/46,553
  transactions carry notes (40%), 10,876 splits a memo, 280 an action.
- **Register ops** — Cut/Copy/Paste (⇧⌘X/C/V), Go to Date (⌘G),
  Schedule-from-transaction, Auto-Split Ledger, a blank entry row at the foot
  (date, description, QuickFill, transfer, signed amount, Return), and editable
  quantity on FX/security legs with the implied rate shown. A Transaction menu
  (Edit ⌘E, Go to Other Account ⌘J, Reconcile State, Duplicate ⌘D, Add
  Reversing, Void/Unvoid, Delete ⌘⌫) via a shared `TransactionActions` view so
  the menu bar and all three context menus can't drift.
- **Account ops** — Cascade Account Properties (opt-in per property), Auto-clear
  (ported from `gnc-autoclear`), Open Subaccounts, the reconcile report; Delete
  Account asks GnuCash's question (where do postings and children go); sidebar
  filter + show-hidden toggle so `isHidden` does something.
- **Data ahead of UI** — Frozen (`f`) reachable via a Reconcile State submenu;
  Rules gained multi-trigger AND/OR, `setNotes`, groups with ordering and
  switches, tag autocomplete from `Book.allTags`. The pattern named: each was
  *implemented and tested* but had no way in, so tests passed while the feature
  did not exist.

## Reports redesign (17 Jul 2026)

The GnuCash reports audit grew into a redesign of the whole surface. The
arithmetic was already good — every report pinned to an identity (trial-balance
columns agree, the equity statement bridges two balance sheets, cash flow's
in − out equals the set's net change) and verified against the reference book —
but the *surface* had five structural problems:

1. **Detached window/modal.** Reports opened in their own window (macOS) / sheet
   (iOS); an analytics surface should live in the detail pane where the data is.
2. **Pregeneration.** Opening Reports immediately computed the default report —
   seconds of work on a 46k-transaction book before the user chose anything.
3. **Recompute-in-`body`.** Reports computed inside SwiftUI `body`, so a
   date-picker interaction recomputed a full-book report per keystroke.
4. **O(accounts × transactions) arithmetic.** Statement reports asked each
   account for its balance and every balance walked the whole book (~26M split
   visits) — the same shape as the `netWorthSeries` bug.
5. **No period vocabulary / configurations / document rendering.** Dates were
   ad-hoc; no financial-year selector, no saved configurations (despite
   FR-RPT-04), and plain `List` rendering that read like another register.

The decisions taken: Reports is an **inline** detail-pane destination (⌘R) with
"Open in New Window" as a secondary command; entering shows a **gallery** and
nothing computes until a report is chosen (`.task(id: configuration)`, never in
`body`); one parameter model (`ReportPeriod` financial-year-aware vocabulary +
Codable `ReportConfiguration` + book-KVP favourites, honouring FR-RPT-04);
**one-pass arithmetic** (`Book.balancesByAccount` gains date bounds); and a
shared **document scaffold** (header, KPI callouts, chart, `Grid` tables with
ruled totals, methodology notes, optional Apple-Intelligence commentary). It
landed across five commits:

| Item | Notes |
|---|---|
| Five new reports | Trial Balance, Equity Statement, Account Summary, Cash Flow with GnuCash semantics (in − out = net change; old projection renamed Forecast), Income & Expense charts. 31 identity tests. |
| One-pass arithmetic | Every statement report walked the book once *per account* (26M split visits). Now one walk per report: accountSummary 15.63s → 0.061s, balanceSheet 7.89s → 0.058s, trialBalance 7.62s → 0.061s, equityStatement 6.77s → 0.129s (debug). Equivalence proven old-vs-new, byte-identical. |
| Period vocabulary + favourites + defaults | `ReportPeriod` named rules resolved against the book's FY start (AUD books default to July); favourites in book KVP, replace-by-name; FY start + default period as book-scoped settings. |
| Inline surface, no pregeneration | Reports live in the detail pane (⌘R); the detached window is an explicit menu item. Nothing computes until a report is chosen; computation runs in a task with a spinner, never in `body`. |
| Document polish + AI notes | Statement reports render through `ReportDocument`: header, KPI callouts, charts, Grid tables with ruled totals, methodology notes, optional on-device commentary (`ReportNarrator`). PDF prints the same value the screen renders. Income Statement FY 2025–26 matches SQL to the cent (233,856.12 / 79,013.41). |
| Commentary live-model check | `ReportNarrator` has a live on-device test (`LiveModelTests.reportCommentary`, ~1s). It surfaced a contract drift (five notes despite a two-to-four guide) — now clamped to four. |
| Average Balance | Daily-weighted average balance per interval (min/max/gain/loss/profit), account-scoped. `FinancialReports.averageBalance` matches GnuCash's chart to zero difference across 15 monthly intervals (4 identity tests). CY 2025 weighted average $281,622.99 agrees across KPI and table. |
| Multicolumn statements | Period-over-period columns via a **Compare: N** stepper on Balance Sheet and Income Statement (0 = single column). Each column reuses the verified per-period computation; the scaffold gained a generic multi-column table (on screen and in PDF). Income Statement FY 2025–26 vs 2024–25 vs 2023–24 align with blanks where an account had no line. |

## Investment reports parity audit (17 Jul 2026)

Figure-verified Advanced Portfolio / Lots / Capital Gains against GnuCash
5.16's own report engine (`gnucash-cli` on an identical copy; a hand-written
saved-report config aligned the options). **Every real holding matches to the
cent** — shares, basis, value, realised, unrealised, under FIFO and average —
and the FIFO grand totals for basis ($2,424,903.45) and realised gain
($925,239.50) matched exactly across ~2,069 disposals spanning 46 years. Total
market value and total gain ($2,983,229.61 / $1,483,565.66) match to the cent.

| Item | Notes | Status |
|---|---|---|
| Phantom lots after an oversell | An uncovered sale discarded the deficit, so a later buy opened a fresh lot instead of covering the short — four long-exited super accounts showed ≈$1,471 of holdings that don't exist. `CostBasis` now carries the shortfall: covering buys close it (zero proceeds, buy-back cost as basis, dated at the cover) and `remainingQuantity` reflects the true balance. | fixed |
| Brokerage-fee treatment | A `FeeTreatment` option (Ignore / Include in basis) on the cost-basis engine and investment reports, as a **Fees** picker. Include-in-basis matches GnuCash's default: Westpac Banking Corp to the cent (basis $6,503.38, realised $174.06). Default stays **Ignore** (our GnuCash-"ignore"-exact baseline). *Known divergence:* this book books non-fee amounts (imputation credits, capital loss, contributions tax) as expense splits inside managed-fund transactions; GnuCash's money-in/out accounting washes them out over a closed position while our per-parcel engine subtracts them (~$34k realised across ~6 accounts). Matching would require adopting GnuCash's money-flow model — deferred (P8), arguably not more correct. | done |
| Average-method rounding | GnuCash rounds each sale's basis progressively; we keep full precision until the report edge — 2¢ drift on one account over 40 years. | wontfix |

## GnuCash report catalogue — build-vs-skip (17 Jul 2026)

Walked GnuCash 5.16's full report menu (65 entries) against our fifteen
`ReportKind`s. Most are already covered, a chart/register variant of something
we have, or business (deferred). **Average Balance** and **multicolumn
statements** were the two genuine net-new analytics — both built (above). The
rest is recorded so "is there parity?" has a written per-report answer:

- **Covered / alias**: Profit & Loss (= Income Statement), Investment Portfolio,
  Net Worth Bar/Line, Income/Expense Chart & Line, Cash Flow, Transaction
  Report, Reconciliation, Balance Forecast, Future Scheduled Summary, single-
  period account pies.
- **Registers cover**: General Journal, General Ledger (our register forms).
- **Marginal variants (skip)**: Cash Flow Barchart, Transaction Breakdown,
  Over-Time charts, Securities, Price.
- **With budget work**: Budget Report chart/statement variants.
- **Tax/business (defer)**: Income & GST Statement, Tax Schedule / TXF Export
  (→ P9 tax tools), IFRS weighted-average cost basis; all invoice/receipt and
  customer/vendor/employee business reports (P7 surfaces below).
- **Novelty/infra (skip)**: Day-of-Week charts, Sample reports/graphs.

## P7 Business features — GnuCash Business menu audit (17 Jul 2026)

Small-business accounting: engine, native persistence, GnuCash-XML round-trip,
and UI are **built and tested**. The reference book has no business objects, so
the engine is verified by accounting identities and GnuCash's documented
arithmetic, cross-checked by round-tripping through GnuCash 5.16.

| GnuCash menu item | Status | Where |
|---|---|---|
| Customer / Vendor / Employee data model | engine + persist | `Business.swift`; SQLite store |
| Job (under customer or vendor) | engine + persist | `Job`, `BusinessOwner.job` |
| New/Find Customer·Vendor·Employee·Job | built | Business hub (⇧⌘B), `BusinessView.swift` |
| New Invoice / Bill / Expense Voucher | built | `InvoiceEditorSheet`, `InvoiceDetailSheet` |
| Post to A/R–A/P (lots + entries) | built | `postInvoice`/`unpostInvoice`; 6 tests |
| Process Payment (apply to invoices) | built | `processPayment` (oldest-first, partial, over-payment → pre-payment lot); 3 tests |
| Sales Tax Table editor | built | `TaxTablesSheet`; `TaxTable`/`TaxTableEntry` |
| Billing Terms editor | built | `BillingTermsSheet`; `BillTerm` |
| Company / business information | built | `CompanyInfo` book-KVP + `CompanyInfoSheet` |
| Receivable/Payable Aging report | built | `aging(forOwner:)`, `agingByOwner(...)`; 2 tests |
| Customer Summary report | built | `ReportKind.customerSummary`; 1 test |
| Printable / Tax Invoice | built | `PrintableInvoice` → PDF; company header + bill-to + lines |
| GnuCash-XML round-trip of business objects | built + tested + GnuCash-verified | owners, addresses, `<act:lots>`, `<split:lot>`, business KVP slots |

**GnuCash 5.16 reads our exported file and attributes postings to their owners**
— Receivable Aging shows Acme $1,450 / Globex $2,200 and Customer Summary shows
Acme $1,500 / Globex $2,000, matching our aging engine to the cent. The earlier
"No Customer" symptom is fixed: GnuCash resolves a posting's owner via a
`gncInvoice` slot **on the transaction** plus `trans-date-due`; `postInvoice`
now writes both on the transaction (regression-tested, confirmed by re-running
GnuCash's own reports).

Business edits are undoable (they ride the whole-book GnuCash-XML snapshot) and
persist through save/reload (SQLite). Remaining P7 tails (in deferred.md): Bills
Due Reminder surface, vendor/employee/job detail reports, Australian-Tax invoice
layout, time & mileage tracking.

## Full GnuCash-source line-by-line audit (17 Jul 2026)

Audited the whole implementation against the real GnuCash C/C++ source (cloned
at `~/Repositories/gnucash-reference`) with a multi-agent sweep over the engine,
XML backend, and import; every confirmed divergence was fixed and every absent
feature implemented.

**Correctness bugs fixed** (each with a test, verified against source):
- **Frozen (`f`) splits** now count in cleared *and* reconciled balances
  (`Account.cpp:2324`) and fold into the reconcile report's reconciled funds.
- **Price lookup**: nearest-in-time (GnuCash's default `pricedb-nearest`), not
  newest-on-or-before; indirect common-currency chaining; `securityUnitValue`
  tries every quote currency; converted balances round-then-sum.
- **Business invoice arithmetic**: per-entry rounding so postings always balance
  (bug 628903); tax-inclusive back-compute; proximo cutoff + real-month clamp.
- **Auto-clear**: skip zero-amount splits; statement-date cutoff.
- **XML round-trip**: `split:reconcile-date`; list-typed KVP bare-value format.
- **Register order**: `xaccTransOrder_num_action` canonical order (numeric
  num/action, then entered/description/guid).
- **Import dedupe**: match on the OFX FITID via the split `online_id` slot
  (GnuCash's definitive match), not just the transaction number.

Stock-transaction shapes (buy/sell/dividend/reinvest/return-of-capital/split)
were audited and already match GnuCash's split structure — no change.

**Absent features implemented** (model + XML round-trip + native store + UI):
- **Amount expression parser** (`gnc-exp-parser`) — `5*3`, `10.50+2`, `(1+2)/3`.
- **SX advance-create / advance-remind days** — create/remind ahead of due.
- **Invoice discount-how** modes — `PRETAX` / `SAMETIME` / `POSTTAX`.
- **Per-period budgets** — `Budget.numPeriods` + `BudgetLine.periodAmounts`,
  unset-period reads as zero, period picker in the editor. New sqlite migrations
  `v3_billterm_cutoff`, `v3_entry_disc_how`.

**Accepted as non-gaps (documented, not fixed):**
- Currency-commodity export emits `cmdty:fraction`/`name` that GnuCash omits for
  ISO currencies. GnuCash reads it without error; round-trip byte-verified.
  Within FR-EXP-02 tolerance.
- `isBalanced` treats a sub-minor-unit residual as balanced (ADR-1 tolerance).
- Price same-date tie-break: GnuCash's is GUID-nondeterministic; ours is the
  deterministic first-inserted — strictly better.

## GnuCash menu parity — Tools / View gaps (18 Jul 2026)

A full audit of every FinvestLens menu against GnuCash's (File → Help), with
GnuCash 5.x open on the same book. The Actions / Tools / View menus (where the
functional verbs live) were read from the running app; the File / Edit /
Reports / Business menus were cross-referenced against the command tree in
`finvestlens/finvestlensApp.swift`. The audit corrected itself (three items
first read as missing — Sort By, Filter By, Go to Date — were already
implemented) and closed five real gaps. Legend: **=** parity · **+** exceeds · **≈** near · **−** gap.

**File** — New/Open/Recent (=), Save/Revert (=), Import (**+**: adds Smart PDF/AI import), Export GnuCash (=), Print via Reports (=), Properties/Settings (=), Close/Quit (=).
**Edit** — Cut/Copy/Paste (=), Find + Find Account (**+**: saved searches, tag search), Edit/Delete Account (=), Preferences/Settings (=), Tax Report Options (=, flags round-trip via `tax-related`/`tax-US`).
**View** — Toolbar/Status Bar (=), **Summary Bar** (=, added by this audit), Basic/Auto-Split/Journal ledger styles (=), Double Line (=), Sort By (=), Filter By (=), Open Subaccounts (=), Refresh (= automatic).
**Transaction** — Enter/Cancel/Duplicate (=), Delete/Void (=), Add Reversing (=), Jump to other account (=), Associate File/`assoc_uri` (=), Cut/Copy/Paste txn (≈ Duplicate covers it).
**Actions** — Transfer (=), Reconcile (=), Auto-clear (≈), Stock Split (=), View Lots (≈ cost-basis report, not a lot editor), Blank Transaction (=), Go to Date (=), Split Transaction (=), Edit Exchange Rate (≈ via Currency Transfer), Scheduled Transactions (=), Budget (**+** rollover/envelope/zero-based), Check & Repair (**+** proposes/previews/one-undo).
**Business** — Customers/Vendors/Employees (=, in the ⇧⌘B hub), Invoices/Bills/Vouchers (=), Receivable/Payable Aging (=).
**Reports** — Assets & Liabilities / Balance Sheet / Net Worth (=), Income & Expense (=), Investment/Portfolio (=), Business Aging + Customer Summary (=), Transaction Report (=), Print/PDF export (=).
**Tools** — Price Database (=), Security Editor (=), General Journal (= register style), Transaction Linked Documents (=, book-wide list), Import Map Editor (≈ our Rules), Close Book (=, Period-End Close), Loan Calculator (=), Online Banking Setup (n/a — bank-file/PDF import by design).
**Windows / Help** — single-window; Reports opens its own window (=); About + onboarding (≈, no bundled manual).

The five gaps closed by the audit:

| Item | Notes |
|---|---|
| Register summary bar | Present / Cleared / Reconciled from the engine's existing `BalanceFilter`, gated off for a mixed-commodity subtree. Matches GnuCash's status strip on CDIA to the cent (Present $256,973.29, Reconciled $57,909.82). |
| Linked Documents list (Book menu) | Book-wide roll-up of every `assoc_uri` link, newest first, missing files flagged — the per-transaction link was only reachable one register row at a time. |
| Loan Calculator (Book menu) | Fixed-rate amortisation in the engine (pure `Decimal`), payment + totals + schedule. $300k @ 6% / 30yr → $1,798.65/mo. Totals summed from the schedule so they agree to the cent. |
| Period-End Close (Book menu) | Moves income/expense into equity as of a date, one balanced closing transaction per currency, undoable, with a per-currency preview (AUD and USD shown separately, never blended). |
| Tax Report Options (Edit menu) | Flag income/expense accounts, assign a tax code, see the schedule. Flags stored in GnuCash's exact `tax-related` / `tax-US` slots so they round-trip. |

**Intentionally not built** (rarely relevant to a personal AUD book): Import Map Editor (GnuCash's Bayesian match store — our rules engine serves the purpose), Online Banking Setup (superseded by bank-file/PDF import), and a bundled help manual. **Where FinvestLens exceeds GnuCash:** AI/PDF Smart Import, saved searches and tag search, envelope/zero-based budgets, a previewing Check & Repair with single-action undo, and the home dashboard with alerts.

**Account-scoped undo (18 Jul 2026).** `updateAccount`, `moveAccount`,
`cascadeProperties` and `setAccountTax` went through `editingWholeBook`, which
serialises the whole book (~6.6s / ~115 MB per edit on the reference book).
Added `editingAccounts([ids], named:)` — the account counterpart of the
transaction-scoped `editing` — which snapshots only the named accounts' value
fields (incl. the KVP frame carrying colour and tax slots) plus their tree slot
(parent + sibling index, restored via a new `Account.addChild(_:at:)`). A tax
toggle is now **0.067s, down from ~6.6s (~100×)**; the pre-existing account-undo
tests pass unchanged, plus three new cases (tax flag, cascade subtree,
move-restores-position).

## Apple Intelligence (13 Jul 2026)

Post-1.0 addition of the `Intelligence` package (FR-AI-01…08, Architecture §11):
PDF statement import with light reconciliation, auto-categorisation, invoice
splitting, dividend statements incl. franking credits, budget suggestion, a
forecast outlook, and Smart Import (drop multiple PDFs, each classified and
routed). Applied invoice/dividend PDFs are stored in a configurable document
folder and linked to their transaction GnuCash-style (`assoc_uri`).

Fixed along the way (pre-existing 1.0 bugs uncovered by GUI testing): File-menu
Save/Revert/Import/Export/Close Book were silently missing
(`CommandGroup(after: .saveItem)` has no anchor in a plain WindowGroup —
re-anchored to `.newItem`); bank-file import never presented its picker on macOS
(replaced the unreliable SwiftUI `.fileImporter` with NSOpenPanel, deferred out
of the view-update transaction). The `finvestlens/statement-date` slot rides
through XML export/import so dual-date duplicate detection survives a round-trip.

## Performance work (15 Jul 2026)

All measured against the reference book (46k txns / 102k prices). See
[architecture.md §10](architecture.md#10-derived-state-and-performance) for the
design.

| Was | Now | What |
|---|---|---|
| Opening a book blocked the main thread | isolated to a `DocumentLoader` global actor, returns `sending FinvestLensDocument` | Graph built off the main actor without making `Book` `Sendable`. `open`/`openBook` are `async`; the root view shows "Opening <book>…"; a second click mid-load can't open a second document. |
| `refreshAll` re-sorted every price | 0.158s → 0.041s (release) | `priceRows`/`rateRows` derived on demand behind a cache dropped in `refreshAll()`/`close()`, with a `derivedRevision` counter carrying the observation dependency. |
| `netWorthSeries` = 1.7 billion split visits | 32.329s → 0.066s (~490×, debug) | Rewritten as one pass in date order carrying a running total per account. Still $3,964,362.15 to the cent. This *was* the "navigating to the Dashboard blocks" and "main-actor tail of an open" symptoms — an algorithm, not a threading problem. |
| Whole-book undo snapshot per edit | pre-capture, transaction- and account-scoped | Each edit captures only what it changes before changing it; no baseline held between edits, so opening a book pays nothing. Register edit 5.79s → 0.26s; account edit 6.6s → 0.067s. |
| Price lookup scanned 102k prices per call | binary-searched index, invalidated on `prices` change | Preserves the scan's exact tie-breaking (first price of the winning date). |
| `balance(of:)` walked the book per call | `balancesByAccount()` one-pass | Account tree converts each account once and rolls subtree sums up. `refreshAll` 33.7s → 0.25s. |
| Journal / General Ledger unusable on 46k | uniform `JournalRow` in a `Table`, cached | No windowing; jumps to either end instant; ⌘↑ reaches the true oldest. |

Remaining perf note: with prices lazy, the ~0.04s of every `refreshAll()` is
`rebuildAccountTree` + `runSearch`; fast enough to feel instant (subtree-only
rebuild is a P8 option if ever needed).

## Usability review (July 2026)

Resolved: File/Book menu bar (New/Open/Open Recent/Import GnuCash/Export/Close/
Revert + every tool panel with shortcuts), lean toolbar with a Tools menu,
GnuCash import UI (File menu + welcome screen), price-target editor, account
re-parenting, stale-lock Break-Lock recovery, iCloud conflict-version resolution
in the external-change banner, welcome recents.

**iOS documents.** New/Open panels are AppKit on macOS; iOS uses `fileImporter`.
Verified in the simulator: welcome → Open… → Files picker → book opens and
renders. iOS books are created in the app's Documents directory (visible in
Files under "On My iPhone ▸ finvestlens") with non-colliding naming. Opening a
book from iCloud Drive / Files works: coordinated reads materialise dataless
files; security-scoped access held for the session with bookmark-backed recents;
lockless fallback where the sibling `.lock` can't be created (verified Box Drive
+ iCloud Drive incl. an evicted file). Recents drop entries whose file is gone.
GnuCash/bank-file import and export are intentionally macOS/iPadOS-only
(`FR-PLT-06`, PRD §5.15).

## HIG review (13 Jul 2026)

Fixed: undo/redo (pre-capture, Edit menu integrated), save-on-quit via
`NSApplicationDelegate` (⌘Q never loses data, releases the lock), Reports in its
own window, window titled with document proxy icon, Esc/⌘. cancels sheets
(+ Return confirms reconcile), toolbar help tags, Title Case buttons, undo
action names ("Undo Delete Transaction", etc.).

## 1.0 PRD audit (13 Jul 2026)

Full code review against the PRD before tagging 1.0. Fixed: hardcoded AUD in the
transaction editor (now derives the transaction currency from the splits'
accounts), silent save failures on book-switch/quit/conflict resolution (now
surfaced, quit cancels on failure), transaction-editor errors no longer silently
dismissed, lock heartbeat timer (idle books no longer go stale-breakable),
autosave (5-minute interval), stale importer/OFX comments.
