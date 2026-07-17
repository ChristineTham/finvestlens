# Deferred backlog (P0–P5)

Tracks items that were in scope for a completed phase but deferred, partial, or
never run. Intentional non-goals (e.g. bit-for-bit arithmetic parity with
GnuCash) are **not** listed.

**Status of the functional backlog:** all functional deficits below have been
**implemented** (see the "Resolved" section). The only items still outstanding
are **CI** and **GnuCash round-trip fidelity / perf validation**, deliberately
left for later.

## Still outstanding (intentionally deferred)

| Item | Origin | Status | Notes | Target |
|---|---|---|---|---|
| CI pipeline + file-header/coverage gate | P0 | absent | Tests run locally; no `.github`. | P6 |
| 100k-txn perf validation (local + SMB/NFS) | P1 (NFR-02, OD-1/2/3) | not-run | Go/no-go for GRDB direct-mode vs working-copy. | P6 |
| Round-trip corpus CI gate | P3 | partial | Interop verified manually via `gnucash-cli`. **14 Jul 2026:** deep round-trip on a real 8.5 MB book (560 accounts, 46,578 txns, 102,706 prices) now **CLEAN** — full graph + balances identical, double export byte-identical. Found & fixed: template-transactions ROOT hijacked the book (orphaning every real account), price/amount precision loss (exporter rounded to currency SCU; now exact rationals with continued-fraction recovery for FX cross-rates), book GUID not re-imported. Re-runnable harness: `FL_ROUNDTRIP_FILE=… swift test --filter LiveFileRoundTripTests`; CI automation still pending. | P6 |
| ~~Richer slot (KVP) round-trip~~ | P3 | **done** | **14 Jul 2026:** all slots on book/account/transaction/split are preserved verbatim through import/export (nested frames, lists, gdate/timespec, guid, numeric, integer); `notes` is lifted into `Account.notes`/`Transaction.notes`. Verified on the real 8.5 MB book (18,646 notes, 3,944 online_id, colours, reconcile-info) — round-trip clean incl. KVP equality. **Commodity fidelity closed too (14 Jul 2026):** `Commodity` gained `exchangeCode`/`getQuotes`/`quoteSource`/`quoteTimezone`/`kvp` (identity stays namespace+mnemonic; backward-compatible Codable + sqlite v2 migration), so `cmdty:xcode`, quote config, and `cmdty:slots` (`user_symbol`) round-trip. The live harness now also compares the export against the **original** file's inventory (slot-key multiset, entity + cmdty element counts) — clean on the real book. | done |
| Budgets/scheduled/business in native GnuCash slots | P3 | partial | Persist as KVP-JSON, not GnuCash XML slots. | P7 |
| iCloud Documents container | P6 (FR-PLT-02) | needs-capability | Sync machinery done + storage-agnostic; enabling the container needs a dev team/provisioning. | P6+ |
| Widgets | P6 (FR-PLT-03) | needs-target | WidgetKit extension target; IntentSupport summaries ready to feed it. | P6+ |
| Quick Look preview | P6 (FR-PLT-03) | needs-target | Quick Look extension target. | P6+ |
| Push notifications for alerts | P6 (FR-PLAN-05) | needs-entitlement | Alerts engine + dashboard done; UNUserNotificationCenter delivery pending. | P6+ |
| Localization (string catalogs) | P6 (NFR-06) | absent | Accessibility labels done; UI strings not yet localized. | P6+ |

## Resolved (functional deficits — implemented)

| Item | FR | Origin | Commit theme |
|---|---|---|---|
| Tags (model + editor + `tag:` search) | FR-TAG-01 | P2 | tags/operator search |
| Operator search language | FR-FIND-01 | P4 | tags/operator search |
| Account codes + renumber | FR-COA | P2 | account renumber |
| Register styles (journal / general ledger) | FR-REG-01 | P2 | register styles |
| Transaction Report | FR-RPT-04 | P4 | transaction report |
| Report PDF export | FR-RPT | P4 | report PDF export |
| Saved searches | FR-FIND-01 | P4 | saved searches |
| Merchant cleanup + heuristic categorisation | FR-RULE-03 | P4 | merchant heuristics |
| Default taxonomy / starter chart | FR-COA-03 | P4 | starter chart |
| Onboarding assistant | FR-PLAN-09 | P4 | onboarding |
| Bill reminders + Financial Calendar + matching | FR-PLAN-01, FR-BILL-01 | P4 | bill reminders |
| Budget rollover / envelope | FR-BUD-02 | P4 | advanced budgets |
| Auto-budget replenish / zero-based | FR-BUD-03, FR-PLAN-04 | P4 | advanced budgets |
| Return-of-capital action | FR-INV-04 | P5 | return-of-capital |
| Investment Lots + Price Scatter + rate of return | FR-RPT-02 | P5 | investment reports |
| Stock splits | FR-INV-04 | P5 | stock splits |
| Security Editor | FR-INV-07 | P5 | security editor |
| Watch lists | FR-PLAN-07 | P5 | watch lists |
| Trading accounts (multi-currency FX balancing) | FR-CUR, FR-REG-07 | P5 | trading accounts |
| Scheduled quote auto-refresh | FR-INV-03 | P5 | quote auto-refresh |
| Rules apply-to-historical + preview | FR-RULE-02 | P5 | (done earlier in P5) |
| What-if scenarios on cash flow | FR-PLAN-03 | P5 | (done earlier in P5) |
| UTI / document-type registration | FR-PLT-04 | P1 | document type + onOpenURL |

## GnuCash parity audit — accounts & transactions (15 Jul 2026)

Audited the register and account functions against a real GnuCash 5.x running
the same book, menu by menu. Three **bugs** came out of it and are fixed
(`EditFidelityTests` pins each; every one was verified to fail with its fix
reverted):

| Bug | Was | Now |
|---|---|---|
| Editing a transaction destroyed share counts and split memos | `EditableSplit` carried only account + amount, so `commit()` rebuilt every split with `quantity: nil` (→ defaults to value) and `memo: ""`. Re-saving an unchanged 100-share/$1,000 buy left **1000 shares**, memo gone. Balance checks can't see it: the *values* still balance. | The editor row carries `quantity`/`memo` through untouched; `asInput` is the single exit point. Verified in the GUI on the real book: the 11,600-share AGL buy re-saves with 11,600 shares and Net Worth unmoved. |
| Voided splits still moved the register's running balance | `Book.balance` excludes voided (`Book.matches`), `refreshRegister` did not — so the register's last balance disagreed with the sidebar and every report. | The row still shows with its amount and `v`; it no longer moves the balance. |
| No Unvoid, and the R column silently un-voided | `cycleReconcileState`'s `default` mapped voided → `n`, one split at a time. | `unvoidTransaction`/`isVoided` added (context menu shows Void or Unvoid); the cycle leaves voided **and** frozen alone. |

A note on this list, after auditing it against the source on 15 Jul 2026:
five of its rows were wrong, all in the direction of overstating the gap.
"Hidden accounts always shown (no toggle)" — the toggle to *mark* an account
hidden existed; only the view filter was missing. "Account-tree filter" — the
filter was already written and tested one file over, for Find. "None available
in Journal style" — Journal had Edit. "Per-split memo/action … preserved
through an edit" — `action` was not preserved, it was destroyed. And
`setReconcileState`/AND-OR were partly surfaced rather than absent. The rows
below are what survived checking; the lesson is that a row here is a claim
about code and ages like one.

Parity gaps found, not yet built (ranked):

| Item | Notes | Target |
|---|---|---|
| ~~Search results are read-only~~ | **Partly done (15 Jul 2026):** a result now selects, and offers **Edit…** (double-click or context menu — the editor opens over the results, so "find, then fix each one" works without leaving them) and **Show in Register**, which clears the query (a non-empty one keeps the results in the detail pane, so the register would never appear), selects the account and scrolls to the row. It opens the *balance-sheet* leg, skipping `Imbalance-*`/`Orphan-*` — those are typed `.bank` by `Scrub`, so on this book "the first split" landed in Imbalance-AUD, which says nothing about where the money went. **Completed 17 Jul 2026:** multi-select bulk actions — set reconcile state (on the *matched* split of each result, the leg the search was about), void, delete — each as one edit and one Undo. Entry into the register arrived the same day (see Register ops), which together with Edit-in-place makes the results workable end to end; the one remaining difference from GnuCash is cosmetic (results are a table, not a register view). | done |
| ~~No structured Find, no ⌘F~~ | **Done (15 Jul 2026):** Find (⌘F, Edit menu) with 14 of GnuCash's 16 criteria, all/any, add/remove rows. The design came from GnuCash's dialog being headed **Split Search**: a criterion tests a *split*, not a transaction, so "Account is CDIA and Reconcile is Reconciled" means one split that is both — a transaction-level rollup wrongly matches a CDIA split plus a different reconciled one, on exactly the multi-split transactions people search for. Results roll up to one row per transaction but keep the matched split, so Show in Register opens the leg you searched for instead of the heuristic's guess. Verified against a figure GnuCash computed: 5,385 reconciled CDIA splits totalling **$57,909.82**, its own status-bar Reconciled balance, to the cent. **Completed 17 Jul 2026:** Closing Entries (the `book_closing` slot, mostly used negated) and All Accounts (the transaction posts to *every* chosen account — a transfer between them); "Type of search" as new/refine/add/delete, composing over the split set and **replayed as a pipeline** on every refresh, so results stay live *and* refinements stay in force; saved find queries in the book's KVP, which GnuCash cannot do. | done |
| ~~Find's account picker is a flat list of 559~~ | **Done (15 Jul 2026):** the Account criterion now opens GnuCash's shape — a collapsed tree of the 9 top-level accounts ("Select Accounts to Match") — behind a button labelled with the choice, plus the filter GnuCash lacks: typing "cdia" flattens the tree to Assets:Joint:CDIA in four keystrokes, matching on the **full** name so a parent's name finds its children. Placeholders are shown but not selectable: they hold no splits, so choosing one would match nothing. The comparator reads "matches any account"/"matches no accounts" rather than the reconcile row's "is"/"is not", because the value is a list. Verified in the GUI on the Ashley Bears book: tree → filter → select CDIA, plus Reconcile is Reconciled, reproduces **Find Results (5385)** — GnuCash's own count. | done |
| ~~Find Account (⌘I)~~ | **Done (17 Jul 2026):** ⌘I, type, Return — the keyboard path the sidebar filter isn't. Return acts on the chosen row or the only match, never on a guess between several. Same `matching` as Find's picker and the sidebar, so all three agree what a search string means. Import Bank File moved to ⌥⌘I: a lookup done many times a session outranks an import done once a statement. | done |
| ~~Free-text `date:2026` degraded silently~~ | **Done (15 Jul 2026):** an unknown `key:` now raises a notice naming the real keys and pointing at ⌘F, and the results pane appears whenever a query is live so "No Results" is visible — previously an empty result showed the *dashboard*, hiding the fact the search ran. It still searches literally rather than erroring, because it has to: this book's memos really contain "Value Date:", and ~20 rows legitimately match it. | done |
| ~~Register Sort By / Filter By~~ | **Done (15 Jul 2026):** Sort menu (Standard Order, Date, Date of Entry, Number, Amount, Description, Memo + Reverse Order) and a Filter sheet (date range + the 5 reconcile statuses), both mirroring GnuCash's View menu. The load-bearing rule came from GnuCash itself, not from guessing: the Balance column is the account's balance **as of that posting**, computed in date order — sort by amount and every row keeps the balance it had; filter rows away and the survivors keep theirs. So the balance is computed once in canonical order, then filtered, then sorted; both are display-only. Verified on CDIA against GnuCash with the same filter and sort: identical rows, order and balances to the cent (238,358.52 → 294,057.07). **Completed 17 Jul 2026:** persisted per account in UserDefaults (as GnuCash keeps the same facts in its state file — arranging a register is looking, not editing, and must not dirty the book; the default arrangement stores nothing), and Date/Description/Amount headers click-to-sort through the same `registerSort` the menu uses. Balance stays unsortable on purpose: each row's balance is the account's balance as of that posting. | done |
| ~~Double-line mode~~ | **Done (15 Jul 2026):** the editor has a Notes field, each split has its own memo and action, and the register has GnuCash's View ▸ Double Line, joining notes · memo · action under the description and only where there is something to say. This was the largest of these gaps by data: 18,641 of 46,553 transactions carry notes (40%), 10,876 splits a memo and 280 an action — all imported from the bank's OFX, round-tripped faithfully, and impossible to read. | done |
| ~~Register ops absent~~ | **Done (17 Jul 2026):** all of it. Cut/Copy/Paste (⇧⌘X/C/V), Go to Date (⌘G), Schedule-from-transaction, Auto-Split Ledger (16 Jul); then an entry bar at the register's foot (GnuCash's blank row: date, description, QuickFill from the last transaction with that description, transfer, signed amount, Return — multi-split entry stays ⌘T's job), and an editable quantity on FX/security legs with the implied rate shown ("10 BHP @ 40 AUD"). The quantity test caught `Decimal(string:)` parsing a numeric *prefix* — "1o" is 1, not an error — so amounts and quantities parse strictly now, or Save is disabled. | done |
| ~~Register ops unreachable~~ | **Done (15 Jul 2026):** a Transaction menu with Edit ⌘E, Go to Other Account ⌘J, Reconcile State, Duplicate ⌘D, Add Reversing, Void/Unvoid and Delete ⌘⌫, and Journal/General Ledger now offer all of them rather than Edit alone. The menu bar cannot see a register's `@State`, so the selection moved onto the model; one `TransactionActions` view serves all three context menus and the menu bar, which is what stops the lists drifting apart again — they already had. | done |
| ~~Per-split memo/action fields~~ | **Done (15 Jul 2026):** both editable, on a second line under each split as GnuCash lays them out. `action` was worse than "not editable": `SplitInput` had no such field, so an edit erased it — see §Data-integrity below. | done |
| ~~Account gaps~~ | **Done (16 Jul 2026):** Cascade Account Properties (each property opt-in and applied on its own — hiding a subtree because someone asked to recolour it would be a surprise); Auto-clear, ported from `gnc-autoclear`; Open Subaccounts, which finally passes `Book.balance(includingDescendants:)` the `true` it was written for; and the reconcile report. Type/commodity remain uneditable after creation, which is arguably right and left deliberately: changing an account's commodity reinterprets every quantity posted to it. | done |
| ~~Account gaps: delete, filter, hidden~~ | **Done (15 Jul 2026):** Delete Account now asks GnuCash's question — where do the postings and children go — instead of refusing outright for any account that has been used, which on 559 accounts was nearly all of them. The sidebar has a filter (reusing Find's tested `matching`) and a show-hidden toggle, so `isHidden` finally does something. | done |
| ~~Data ahead of UI~~ | **Done (15 Jul 2026):** all of it has a surface now. Frozen (`f`) is reachable from a Reconcile State submenu — `setReconcileState` handled all five states from the start and had no caller outside its tests. Rules gained multi-trigger AND/OR, the `setNotes` action, groups with ordering and per-group/per-rule switches, and tag autocomplete from `Book.allTags`. The pattern is worth naming: each of these was *implemented and tested* and simply had no way in, so the tests all passed while the feature did not exist. | done |

Data-integrity bug found while auditing this list (15 Jul 2026):

| Bug | Was | Now |
|---|---|---|
| Editing a transaction silently un-reconciled it | `updateTransaction` rebuilt every split from `SplitInput`, which carried only account, value, quantity and memo. Everything else came back as a constructor default: `reconcileState` reset to `n`, `reconcileDate` and the preserved KVP slots dropped, `action` lost, the split's guid regenerated. Retyping a description was enough. 34,939 of 46,553 transactions have a reconciled or cleared split, so the status-bar Reconciled balance — $57,909.82, matching GnuCash to the cent — would have walked down as transactions were edited. As with the share-count bug, the values still balanced, so nothing downstream could see it. | The save re-attaches to the split each row came from, keyed by a `splitID` the row carries; what the editor never showed survives because it is never copied. Separately, the save assigned `dateEntered = datePosted` on every edit — every transaction in this book has an entry date later than its posting date, and the register sorts by it. |

## Reports redesign (17 Jul 2026)

The GnuCash reports audit grew into a redesign of the whole surface — see
docs/reports.md for the findings and decisions. Landed across five commits:

| Item | Notes | Status |
|---|---|---|
| Five new reports | Trial Balance (columns must agree; unrealised adjustment printed), Equity Statement (the bridge between two balance sheets), Account Summary (every depth sums to the same totals), Cash Flow with GnuCash semantics (in − out = the set's net change; the old projection renamed Forecast), Income & Expense charts (slices sum to the income statement). 31 identity tests. | done |
| One-pass arithmetic | Every statement report walked the book once *per account* (26M split visits). Now one walk per report: accountSummary 15.63s → 0.061s, balanceSheet 7.89s → 0.058s, trialBalance 7.62s → 0.061s, equityStatement 6.77s → 0.129s (debug, reference book). Equivalence proven old-vs-new on the real book, byte-identical. | done |
| Period vocabulary + favourites + defaults | `ReportPeriod` named rules resolved against the book's FY start (AUD books default to July); favourites saved in book KVP, replace-by-name (FR-RPT-04's "save report configurations", finally); FY start + default period as book-scoped settings that write nothing until changed. | done |
| Inline surface, no pregeneration | Reports live in the detail pane (⌘R); the detached window is an explicit menu item. Entering shows a gallery; nothing computes until a report is chosen, and computation runs in a task with a spinner — never in `body`, which used to recompute a 7s report per UI tick. | done |
| Document polish + AI notes | Statement reports render through `ReportDocument`: header, KPI callouts, charts, Grid tables with ruled totals, methodology notes, optional on-device commentary (`ReportNarrator` — figures arrive computed; the model observes, never calculates). PDF prints the same value the screen renders. Verified on the reference book: Income Statement FY 2025–26 matches SQL to the cent (233,856.12 / 79,013.41). | done |
| Legacy report internals | Transactions, Reconciliation, Forecast, Portfolio, Investment Lots, Price Scatter, Capital Gains keep their interactive views inside the new navigation; migrating their internals to the document scaffold (and giving them PDF export) is follow-up. | P8 |
| Commentary live-model check | **Done.** `ReportNarrator` now has its own live on-device test (`LiveModelTests.reportCommentary`), which runs with real Apple Intelligence inference on an eligible machine (verified passing, ~1s). It surfaced a real contract drift — the model sometimes returned five notes despite the "two-to-four" guide — now enforced by clamping the narrator's output to four. | done |

## Investment reports parity audit (17 Jul 2026)

Figure-verified Advanced Portfolio / Lots / Capital Gains against GnuCash
5.16's own report engine (`gnucash-cli` on an identical copy of the reference
book; a hand-written saved-report config aligned the options). Result: **every
real holding matches to the cent** — shares, basis, value, realised,
unrealised, under both FIFO and average — and the FIFO grand totals for basis
($2,424,903.45 pre-fix) and realised gain ($925,239.50) matched exactly across
~2,069 disposals spanning 46 years. Total market value and total gain
($2,983,229.61 / $1,483,565.66) match GnuCash to the cent after the fix below.

| Item | Notes | Status |
|---|---|---|
| Phantom lots after an oversell | An uncovered sale discarded the deficit, so a later buy opened a fresh lot instead of covering the short — four long-exited super accounts (WSSP-*, AMP BB Investment) showed ≈$1,471 of holdings that do not exist. `CostBasis` now carries the shortfall: covering buys close it (zero proceeds, buy-back cost as basis, dated at the cover) and `remainingQuantity` reflects the true balance. GnuCash has the same lot quirk (stranded basis on zero units, self-inconsistent rows); ours now drops fully-exited rows instead. | fixed |
| Brokerage-fee treatment | **Built.** A `FeeTreatment` option (Ignore / Include in basis) on the cost-basis engine and the investment reports (Portfolio, Lots, Capital Gains), surfaced as a **Fees** picker. Include-in-basis folds a buy's brokerage into the lot cost and a sale's into realised cost, matching GnuCash's default. Verified against GnuCash 5.16's own include-in-basis run: **Westpac Banking Corp matches to the cent** (basis $6,503.38, realised $174.06), and every ordinary holding's basis rises by exactly its commission. Default stays **Ignore** (our GnuCash-"ignore"-exact baseline). *Known divergence:* this reference book books non-fee amounts (Imputation credits, Capital Loss, contributions tax) as expense splits *inside* managed-fund (MUTUAL) transactions — GnuCash's money-in/money-out accounting makes those wash out over a fully-closed position, while our per-parcel engine subtracts them; ~$34k of realised across ~6 super/managed-fund accounts (e.g. MLC Assertive). Matching that would require adopting GnuCash's money-flow realised model — deferred, and arguably not more correct. The extra Advanced Portfolio columns (Money In/Out, Income, Rate-of-Return) remain P8. | done / P8 |
| Per-lot oracle | GnuCash's Investment Lots report needs explicit lot records; the reference book has none, so lots were verified through the basis/realised columns instead. Nothing further owed. | done |
| Average-method rounding | GnuCash rounds each sale's basis to cents progressively; we keep full precision until the report edge — 2¢ drift on one account over 40 years. Not worth chasing. | wontfix |

## GnuCash report catalogue — build-vs-skip (17 Jul 2026)

Walked GnuCash 5.16's full report menu (65 entries) against our fifteen
`ReportKind`s and decided each. Most of the catalogue is either already
covered, a chart/register variant of something we have, or a business
feature already deferred to P7. Two entries are genuine net-new analytics:
**Average Balance** (built this session) and **multicolumn period-comparison
statements** (flagged for a future build). The rest is recorded so the
"is there parity?" question has a written answer per report.

| Report(s) | Decision | Reason |
|---|---|---|
| **Average Balance** | **built** | Daily-weighted average balance per interval (min/max/gain/loss/profit), account-scoped. `FinancialReports.averageBalance` matches GnuCash's chart to zero difference across 15 monthly intervals on the Torrens account (4 identity tests). Wired onto the report scaffold (Activity group): a `step` parameter on `ReportConfiguration` (week…year), the account-scope picker, a bar chart of averages, and the interval table with a weighted-average total. Verified in the GUI on the reference book — CY 2025 weighted average $281,622.99 agrees across the KPI and the quarterly table's total; period and interval changes recompute correctly. The richer per-interval columns (min/max/gain/loss) are held for the multi-column table work below. |
| Balance Sheet / Income Statement **(Multicolumn)** | **built** | Period-over-period columns via a **Compare: N** stepper on the existing Balance Sheet and Income Statement (0 = single column, as before). Each column reuses the already-verified per-period `balanceSheet`/`incomeStatement`, so the figures inherit that verification; the new logic (column windows stepping back by the period's own unit, labels, and row alignment by account across periods) is unit-tested. The scaffold gained a generic multi-column table (`ReportDocumentSection.columns`/`columnTotals`, rendered on screen and in the PDF). GUI-verified: Income Statement FY 2025–26 vs 2024–25 vs 2023–24 columns align with blanks where an account had no line; Balance Sheet as-of columns balance. The `comparePeriods` stepper hides for periods that don't tile (all time, last 12 months, custom). The same multi-column table is available to give Average Balance its per-interval min/max/gain/loss columns — a small follow-up, not yet wired. |
| Profit & Loss; Investment Portfolio; Net Worth Bar/Linechart; Income/Expense Chart & Linechart; Cash Flow; Transaction Report; Reconciliation Report; Balance Forecast; Future Scheduled Transactions Summary; Income/Expense/Assets/Liabilities Accounts (single-period pies) | skip — covered | Each is one of our existing kinds or an alias/chart of one (P&L = Income Statement; the account pies = Balance Sheet / Income & Expense; Balance Forecast + Scheduled Summary = Forecast). |
| General Journal; General Ledger | skip — registers cover | These are register *forms*; our Journal / General Ledger registers already provide all transaction ops. Same call as the register-styles row above. |
| Cash Flow Barchart; Transaction Breakdown; Assets/Liabilities/Income/Expense **Over Time**; Securities; Price | skip — marginal variant | Chart or breakdown variants of Cash Flow / Transactions / Net Worth series / the price UI; no new information for the effort. Revisit only on request. |
| Budget Report **variants** (Chart, Flow, Balance Sheet, Income Statement, Profit & Loss) | skip — with budget work | We have `BudgetReport`; the chart/statement variants belong with the deferred advanced-budget work (P4 rows above), not the report audit. |
| Income and GST Statement; Tax Schedule Report / TXF Export; IFRS weighted-average cost basis | defer — tax/business | GST statement is business/GST-flavoured (P7); TXF export belongs with the P9 tax tools; IFRS weighted-average is a niche cost-basis variant (our average method already feeds Advanced Portfolio / Capital Gains). |
| All invoices/receipts (Easy, Fancy, Printable, Tax, Australian Tax, Receipt); Customer/Vendor/Employee/Job Report; Customer Summary; Payable/Receivable Aging | skip — business (P7) | Business objects are a whole deferred phase (see the business rows above and porting.md). |
| Expenses/Income vs. Day of Week; Sample Report; Sample Graphs; Multicolumn View | skip — novelty/infra | Novelty charts and GnuCash's own demo/infrastructure reports; no parity obligation. |

## P7 Business features — GnuCash Business menu audit (17 Jul 2026)

Started P7 (`FR-BUS-01..06`). The reference book has no business objects, so
there is no live oracle yet — the engine is verified by accounting identities
and GnuCash's documented arithmetic, and a GnuCash-authored business book is
owed for a numeric cross-check. **The engine and native persistence are built
and tested (26 tests); the interop XML round-trip and the whole UI are the
remaining phases.** Every GnuCash Business-menu item, mapped:

| GnuCash menu item | Status | Where |
|---|---|---|
| Customer / Vendor / Employee — data model (contact, terms, tax table, currency, discount, credit) | **engine + persist done** | `Customer`/`Vendor`/`Employee` in `Business.swift`; round-trips in the SQLite store |
| Job (under customer or vendor) | **engine + persist done** | `Job`, `BusinessOwner.job` |
| New/Find Customer·Vendor·Employee·Job (create + browse) | **built** | Business hub (⇧⌘B): New Customer/Vendor/Employee/Job editors + lists in `BusinessView.swift` |
| New Invoice / New Bill / New Expense Voucher (document with line entries) | **built** | `InvoiceEditorSheet` (line entries, tax tables, post-immediately); `InvoiceDetailSheet` |
| Post invoice/bill to A/R–A/P (via lots and entries) | **built** | `postInvoice`/`unpostInvoice`; balanced txn + settlement lot; Post/Unpost in invoice detail; 6 tests |
| Process Payment (customer/vendor, apply to invoices) | **built** | `processPayment` (oldest-first, partial, over-payment → pre-payment lot); `ProcessPaymentSheet`; 3 tests |
| Sales Tax Table editor | **built** | `TaxTablesSheet` (list + add, percentage into a tax account); `TaxTable`/`TaxTableEntry` |
| Billing Terms editor | **built** | `BillingTermsSheet` (list + add, net-days or proximo); `BillTerm` |
| Company / business information (File ▸ Properties ▸ Business) | **built** | `CompanyInfo` book-KVP struct + `CompanyInfoSheet` in the Business hub Setup section |
| Bills Due Reminder | partial (engine) | `aging`/`agingByOwner` give the data; the reminder surface is todo |
| **Reports ▸ Business ▸ Receivable/Payable Aging** | **built** | `aging(forOwner:)`, `agingByOwner(receivable:)` — 0-30/31-60/61-90/91+ buckets on the scaffold; 2 tests |
| Reports ▸ Business ▸ Customer Summary | **built** | `ReportKind.customerSummary` — invoiced / paid / outstanding per customer on the scaffold; 1 test. Vendor/Employee/Job detail reports still todo |
| Printable / Tax Invoice | **built** | `PrintableInvoice` rendered to PDF via `ReportExport.pdf` + file exporter ("Save PDF…" in invoice detail); company header + bill-to + lines + totals. Australian-Tax-specific layout todo |
| **GnuCash-XML round-trip** of business objects (`FR-IMP-05`/`FR-EXP`) | **built + tested + GnuCash-verified** | `GncCustomer/Vendor/Employee/Job/Invoice/Entry/BillTerm/TaxTable`, owners, addresses, `<act:lots>` and `<split:lot>`, and the business KVP slots (`gncInvoice`/`gncOwner`/`trans-txn-type`). Export→import preserves the whole graph incl. the posted lot and outstanding balance (round-trip tests). **GnuCash 5.16 now reads our exported file and attributes the postings correctly to their owners** — Receivable Aging shows Acme $1,450 / Globex $2,200 and Customer Summary shows Acme $1,500 / Globex $2,000 (matching our own aging engine to the cent). *The earlier "No Customer" symptom is fixed:* diffing our export against GnuCash's own `sample1.gnucash` (whose Payable Aging worked) showed GnuCash resolves a posting's owner via a `gncInvoice` slot **on the transaction** (`gncInvoiceGetInvoiceFromTxn`) plus `trans-date-due` — we set those on the lot only. `postInvoice` now writes both on the transaction too (`BusinessPosting.swift`), regression-tested, and the fix was empirically confirmed by re-running GnuCash's Receivable Aging / Customer Summary on the regenerated file. |

Engine coverage so far: object model + entry/invoice arithmetic (pre-tax
discount, percentage & flat tax, grouped by account), A/R–A/P posting via lots,
payments, aging — all identity-verified. The `AppModel` bridge
(`AppModel+Business.swift`) exposes create/post/pay/aging as undoable edits and
is flow-tested end to end; business objects persist through save/reload (SQLite).

**Undo now works.** The whole-book undo snapshots via GnuCash-XML export
(`editingWholeBook` → `gnuCashExportData`); now that business objects are in
that round-trip, a business edit is undoable — verified by round-tripping the
exact whole-book snapshot undo uses (customer + posted invoice + outstanding
survive).

Next: the Business menu, editors and reports (the report surfaces can reuse the
`aging`/`agingByOwner` engine data), and — for a to-the-cent numeric
cross-check — the last-mile GnuCash lot↔owner reconstruction so GnuCash's own
aging report attributes our postings.

## Usability review (July 2026)

Resolved in the usability pass: File/Book menu bar (New/Open/Open Recent/
Import GnuCash/Export/Close/Revert + every tool panel with shortcuts), lean
toolbar with a Tools menu, GnuCash import UI (File menu + welcome screen),
price-target editor, account re-parenting, stale-lock Break-Lock recovery,
iCloud conflict-version resolution in the external-change banner, welcome
recents.

Still deferred:

| Item | Notes |
| --- | --- |
| App Sandbox | Disabled by decision (13 Jul 2026): sibling `.lock` files at user-selected locations are denied by the sandbox; related-item declaration + coordinated I/O are in place but macOS still refused. Direct (notarized) distribution doesn't need the sandbox. Revisit before any Mac App Store submission. |
| iOS document flows | New/Open panels are AppKit on macOS; iOS uses fileImporter. First run in the simulator 14 Jul 2026: welcome → Open… → Files picker → book opens and renders. **New Book fixed (14 Jul 2026):** iOS books are created in the app's Documents directory (visible in Files under "On My iPhone ▸ finvestlens") with non-colliding Untitled/Untitled 2 naming — no longer the purgeable temporary directory. Still open: a move/rename flow for new books. **GnuCash/bank-file import and export are intentionally macOS/iPadOS-only** (`FR-PLT-06`, PRD §5.15) — iPhone is open/create/edit only, so their absence on iOS is by design, not a gap. |
| ~~iOS: open a book from iCloud Drive / Files~~ | **Done (14 Jul 2026):** coordinated reads materialise dataless files; security-scoped access held for the session with bookmark-backed recents; lockless fallback (Architecture §6.1/§6.3) where the sibling `.lock` can't be created. Verified: Box Drive + iCloud Drive (incl. evicted file) on macOS, Files-picker open in the iOS simulator. Dropbox uses the same File Provider mechanism as Box (not separately tested — not installed). | 

## HIG review (13 Jul 2026)

Fixed: undo/redo (pre-capture, Edit menu integrated), save-on-quit via
NSApplicationDelegate (⌘Q never loses data, releases the lock), Reports in
its own window, window titled with document proxy icon, Esc/⌘. cancels
sheets (+ Return confirms reconcile), toolbar help tags, Title Case buttons.

Known nuances / still deferred:

| Item | Notes |
| --- | --- |
| Esc inside a focused text field | AppKit's field editor consumes the raw Escape (completion); ⌘. always cancels, Esc works otherwise. SwiftUI offers no clean override. |
| ~~Undo action names~~ | **Done (15 Jul 2026):** pre-capture undo names each edit at the call site, so the Edit menu reads "Undo Delete Transaction", "Undo Change Reconcile State", etc. |
| Window/state restoration | App launches to the splash; does not reopen the last book automatically. |
| Help menu | No help book / anchors. |

## 1.0 PRD audit (13 Jul 2026)

Full code review against the PRD before tagging 1.0. Fixed during the audit:
hardcoded AUD in the transaction editor (now derives the transaction currency
from the splits' accounts), silent save failures on book-switch/quit/conflict
resolution (now surfaced, quit cancels on failure), transaction-editor errors
no longer silently dismissed, **lock heartbeat timer** (idle books no longer
go stale-breakable), **autosave** (5-minute interval), stale importer/OFX
comments.

Known 1.0 scope limits (post-1.0 backlog, in priority order):

| Item | FR | Notes | Target |
|---|---|---|---|
| QIF splits + investment actions | FR-XIO-01 | Parser handles flat D/T/U/P/M/N/L cash rows only; `S/E/$` splits and `!Type:Invst` actions dropped. | P8 |
| OFX investment statements | FR-XIO-02 | Only `<STMTTRN>` cash rows parsed; `<INVBUY>`/`<INVSELL>` ignored (use the Stock Assistant). | P8 |
| CSV price import | FR-XIO-03 | CSV imports transactions only. | P8 |
| CSV export | FR-XIO-06 | No CSV export (GnuCash XML export covers interchange). | P8 |
| CSV mapping profiles | FR-XIO-08 | Column mapping is per-import; no saved profiles. | P8 |
| GnuCash `sx:`/budget/business import | FR-IMP-03/05 | Counted as import warnings; FinvestLens keeps its own in KVP slots. | P7/P8 |
| Savings goals / piggy banks | FR-GOAL-01 | Not implemented. | P9 |
| Twelve Data quote provider | FR-INV-03b | Yahoo/EODHD/Alpha Vantage/Finnhub shipped; Twelve Data/Stooq not. | P8 |
| Scheduled-split formulas | FR-SCH-02 | Fixed amounts only. | P8 |
| Re-open a finished reconciliation | FR-REC-03 | Begin/toggle/finish/cancel only. | P8 |
| Loan amortization assistant | FR-SCH-04 | Not implemented. | P9 |
| Transaction attachments | FR-REG-10 | Not implemented. | P8 |
| Check printing | FR-REG-11 | Not implemented. | P9 |
| Open Read-Only on live lock | §6.1 | Open fails with holder info + Break-Lock; no read-only mode. | P7 |
| Autosave interval setting | §3 | Fixed 5 min; not user-configurable/disableable yet. | P7 |
| Business (P7), bank sync/MT940/CAMT (P8), planners (P9) | FR-BUS, FR-XIO-04/07, FR-PLAN-10.. | Post-1.0 phases per plan.md. | P7–P9 |

## Apple Intelligence (13 Jul 2026)

Post-1.0 addition of the `Intelligence` package (FR-AI-01…06, Architecture
§11). Fixed along the way (pre-existing 1.0 bugs uncovered by GUI testing):
**File-menu Save/Revert/Import/Export/Close Book were silently missing**
(`CommandGroup(after: .saveItem)` has no anchor in a plain WindowGroup —
re-anchored to `.newItem`), and **bank-file import never presented its picker
on macOS** (SwiftUI `.fileImporter` unreliable here; replaced with NSOpenPanel,
deferred out of the view-update transaction).

Known limits:

| Item | FR | Notes | Target |
|---|---|---|---|
| Guardrail refusals | FR-AI-05 | On-device safety layer deterministically refuses some borderline inputs; budget advisor retries simplified phrasing then falls back to average-based plan. Other features surface a friendly message. | monitor |
| Scanned-statement OCR quality | FR-AI-01 | Vision OCR fallback is untested against real bank scans; digital-PDF reflow is solid. | P8 |
| Statement sign inference without balance column | FR-AI-01 | Signs are re-derived from the running balance; statements with unsigned debit/credit columns *and* no balance column may import with wrong signs (review screen catches). | P8 |
| ~~Invoice → attachment link~~ | FR-AI-03 | **Done (FR-AI-08):** Smart Import copies applied invoice/dividend PDFs into the document folder and links them via the GnuCash `assoc_uri` slot ("Open Linked Document" in the register). Manual attach from the transaction editor is still not offered. | done / P8 |
| iOS file pickers | FR-AI-01/03/04/07 | iOS keeps `.fileImporter`; not yet exercised on-device. | P8 |
| Smart Import: create transaction from unmatched invoice | FR-AI-07 | An invoice with no matching register transaction reports "import the bank statement first"; direct creation (with funding-account picker) not offered yet. | P8 |
| ~~statementDate in GnuCash XML~~ | FR-AI-07 | **Done (14 Jul 2026):** with generic KVP round-trip, the `finvestlens/statement-date` slot now rides through XML export/import (timespec, full fidelity), so dual-date duplicate detection survives a GnuCash round-trip. GnuCash itself ignores but preserves the slot. | done |
| Live-model tests under load | — | `LiveModelTests` can time out when the model daemon is busy; they self-skip without Apple Intelligence. Not in CI. | monitor |
| ~~Opening a book blocks the main thread~~ | FR-DOC-01 | **Done (15 Jul 2026):** `FinvestLensDocument.load` is isolated to a `DocumentLoader` global actor and returns `sending FinvestLensDocument`, so the graph is built off the main actor and transferred without making `Book` `Sendable` (Architecture §12.6). `AppModel.open`/`openBook` are `async`; the root view shows "Opening <book>…" while `openingURL` is set, and `openBook` guards on `isOpening` so a second click mid-load can't open a second document over the first. Verified in the GUI on the Ashley Bears book: window live throughout, Net Worth/Assets/CDIA unchanged to the cent. `DocumentLoaderTests` pins the executor off the main thread. | done |
| ~~Refreshing derived state re-sorts every price~~ | FR-DOC-01 | **Done (15 Jul 2026):** `priceRows`/`rateRows` are derived on demand behind a cache dropped in `refreshAll()`/`close()`, with a `derivedRevision` counter carrying the observation dependency (Architecture §12.5). `refreshAll` (release) **0.158s → 0.041s**; 0.174s → 0.062s with a 9,018-split register selected. Note the old "0.25s per edit" was a *debug* figure — see §12.7. `LazyPriceRowTests` pins cache invalidation on edit and close. | done |
| `rebuildAccountTree` re-walks the book per edit | FR-DOC-01 | With prices lazy, the remaining ~0.04s of every `refreshAll()` is `rebuildAccountTree` (single-pass balances + one conversion per account) and `runSearch`. Fast enough to feel instant; the next move, if ever needed, is to rebuild only the affected subtree. | P8 |
| ~~Navigating **to the Dashboard** blocks the main thread~~ | FR-DOC-01 | **Done (15 Jul 2026):** the diagnosis in this row was wrong. It read as a threading problem — "derive the dashboard off the main actor, or cache it" — and it was an algorithm. `netWorthSeries` asked each account for its balance at each date, and every balance walked the whole book: 12 dates × 559 accounts × 46,553 transactions ≈ **1.7 billion split visits**, measured at **32.329s** (debug). Rewritten as one pass in date order carrying a running total per account: **0.066s**, ~490× less, still $3,964,362.15 to the cent. Nothing moved off the main actor, because there is no longer anything worth moving. The ~7s of 100% CPU on Clear→Dashboard is now a single 17% sample. `NetWorthSeriesEquivalenceTests` pins the new shape against the old one on a book carrying the awkward cases (moving FX rate, security at market, security with no price, voided split, placeholder, far-future txn). | done |
| ~~The **main-actor tail of an open** is most of the open~~ | FR-DOC-01 | **Done (15 Jul 2026):** the tail *was* the dashboard — same root cause as the row above, paid on every open rather than every Clear. With `netWorthSeries` fixed, a full open on this book goes from **~26s** of busy CPU to **~6.3s** (identical 7.9s click latency in both runs), which is essentially just `store.read()` at 5.6s. The progress bar now meters nearly the whole open rather than a quarter of it. What is left after the read is `reloadKvpCollections` + `refreshAll` at ~0.04s (see the `rebuildAccountTree` row) — no longer worth a fix. | done |
