# Performance Review

*Audited at HEAD (July 2026) against the reference book (559 accounts, ~46k
transactions / ~140k splits, ~35 securities, 100k+ prices). Method: traced the
render/refresh paths of the register, sidebar, dashboard and reports; swept
every `AppModel` computed property and report function for per-render
full-book scans; checked every long-running operation for progress feedback.
Companion to `usability-review.md` — the phases merge there.*

**Targets.** Register/account open: content visible **<100 ms**. Any body pass
(click, focus, hover): **<16 ms** of main-thread work. Anything that must take
longer than ~300 ms shows determinate progress (or a spinner when
indeterminate) and never blocks interaction with the rest of the window.

---

## 1. Already fast (this session's work — don't redo)

| Area | Mechanism |
|---|---|
| GUID lookups (`transaction(with:)`, `split(with:)`) | lazy dictionary indexes, invalidated on edit; miss rebuilds once per generation |
| Price lookups | pair/commodity index (pre-existing) |
| Register row array | `registerRows` stored; `autoSplitRows` one-entry memo keyed by expansion — unchanged passes return the identical array |
| Journal / general ledger rows | per-account caches, invalidated on edit or view-setting change |
| Report functions (balanceSheet, incomeStatement, categoryBreakdown, netWorthSeries, portfolio) | `cachedReport` memo keyed by `derivedRevision` + call signature; dashboard pins dates (`todayCap`) so keys stay stable |
| Account tree balances | one `balancesByAccount()` pass + one FX conversion per account (was quadratic) |
| Window resize | width quantised to 8 pt before it re-enters layout |
| Attachment matching / OCR / AI batch | physical-core-wide task group, one model call per file, cancellable, determinate progress |

## 2. Findings

Cost classes: **scan** = O(book) full-transaction walk · **sort** = O(n log n)
over the book · **flatten** = O(accounts). Frequency is what turns cost into
lag: *per-render* ≫ *per-edit* ≫ *per-open* ≫ *on-demand*.

### P1 — `registerSummary`: three full-book scans per register body pass  *(critical)*

`AppModel.registerSummary` (AppModel.swift ~1889) calls `book.balance(of:)`
three times (all/cleared/reconciled) — each a full 140k-split scan — and it is
a **computed property read in the register's `body`**. Every click, selection
change, and field focus in the register pays ~3 × O(book) on the main thread.
This is the single biggest register-responsiveness bug.

**Fix.** Compute once per register refresh: one pass over the focus accounts'
splits accumulating all three filters simultaneously (the register build
already walks exactly these splits — fold the sums into `refreshRegister()`
and store a `RegisterSummary` snapshot). Body reads the snapshot.

### P2 — `descriptionSuggestions` sorts 46k transactions per keystroke  *(critical)*

AppModel+Editing.swift ~1192: `book.transactions.sorted(by: datePosted >)`
runs on **every keystroke** of the New Transaction description field before a
prefix scan. Typing in the editor lags on a large book.

**Fix.** Maintain a cached recency-ordered description list (or reuse the
journal cache's date order reversed), invalidated by `derivedRevision`;
keystrokes then do a prefix scan over strings only. Same treatment for
`quickFill`'s template lookup if it shares the scan.

### P3 — Reports computed synchronously in `body`  *(major; also the progress-bar gap)*

Confirmed sync-in-body sites (ReportsView.swift):
`advancedPortfolio()` (:72), `reconcileReport` (:286), `transactionReport`
(:391), `investmentLots()` (:435), `capitalGains()` (:532) — lot matching over
the whole book, seconds on first run — and `cashFlowForecast` (:637); plus
`closingPreview` in Period-End Close (ParityViews.swift:193). Each recomputes
on *every body pass* of its view and blocks the main thread — the beachball on
opening Capital Gains is this.

**Fix (pattern, applied to all).**
1. Route results through `cachedReport` (parameter-keyed, revision-invalidated)
   so recomputes happen once per book state.
2. Compute off the body: `.task(id: params)` populating `@State`, with a
   **ProgressView placeholder** ("Building Capital Gains…") on first load and
   a lightweight refresh indicator on parameter change.
3. Heavy pure functions (capital gains, lots, advanced portfolio) get
   `nonisolated` cores so the task genuinely leaves the main actor.

### P4 — `postableAccounts` re-flattens the tree on every call  *(major by multiplication)*

Views.swift ~136: flatten(559 nodes) + filter per call — called by **every
`AccountField` / `AccountPickerButton` render** (dozens of visible cells ×
every body pass), plus editors and sheets.

**Fix.** Cache the flattened array alongside `accountTree` (rebuilt in
`rebuildAccountTree()`), plus the derived `securityAccountNodes` /
`incomeAccountNodes` / cash-account lists that filter it.

### P5 — `refreshAll()` cost per edit  *(major for editing feel)*

Every committed edit runs: `rebuildAccountTree()` (full `balancesByAccount`
pass + FX per account) + `refreshRegister()` (full split scan + sort) +
`runSearch()` + journal cache invalidation. Single edits feel it as a small
hitch; loops of edits multiply it.

**Fixes.**
1. **Coalesce**: ensure every batch path (imports, bulk edit, match-apply,
   auto-categorise apply) performs one `editing…` block → one `refreshAll`
   (bulk edit already does; audit import/apply loops).
2. **Skip dead work**: `runSearch()` only when a query is active; skip
   register rebuild when no selected account; widget publish debounced.
3. **Defer**: journal/GL caches already rebuild lazily on next access — keep.
4. *(Phase 3, only if still felt)* incremental tree balances: adjust the
   touched accounts' totals instead of re-walking the book.

### P6 — `smartCategoryPlans` blocks the main thread on sheet open  *(moderate)*

Auto-Categorise's `.task` builds the corpus (tokenising up to 46k
transactions) synchronously on the main actor — the "Looking for
uncategorised…" spinner freezes instead of spinning.

**Fix.** `nonisolated` corpus build over value snapshots; keep the spinner
honest. Same for `matchStaged` duplicate-detection on big imports if profiling
shows it.

### P7 — General Ledger rebuild after every edit while open  *(moderate)*

`journalRows(forAccountID: nil)` = 46k-transaction sort + 140k rows, rebuilt
on next access after any edit. Acceptable when GL is occasional; noted for the
incremental option if GL becomes a daily surface.

### P8 — Minor per-render costs  *(small, cumulative)*

- `AttachmentsPanel` re-checks `FileManager.fileExists` + percent-decodes per
  render — cache per selected transaction.
- `transactionsForLinking` formats dates per row per keystroke — precompute.
- Sidebar filter runs `AccountMatchPicker.matching` per keystroke over the
  tree — fine at 559, unify with `AccountSearch` anyway (usability Phase 0).

### P9 — Whole-book undo snapshots serialize the entire book  *(critical)*

`editingWholeBook` (AppModel.swift ~1630) captures its undo state via
`gnuCashExportData()` — a **full GnuCash-XML export of 46k transactions and
100k+ prices** — before the edit. It has ~29 call sites: every quote fetch,
every price add/delete, every FX-rate record, quote-symbol change, business
edit, even settings toggles (`autoRefreshQuotes`). Each pays seconds of CPU
and a large transient allocation; `recordFxRate` inside the editor pays it on
Apply.

**Fix.** Scoped snapshots per domain: price operations snapshot only the
`prices` array (value types — a cheap copy); kvp/settings ops snapshot the kvp
frame; business ops snapshot the business tables. Reserve the whole-book
export for genuinely structural operations (GnuCash import, period-end close),
and run even those off the main actor with progress.

### P10 — Save is a synchronous full-file rewrite on the main thread  *(major)*

`FinvestLensDocument.save()` fingerprints the file, rewrites the **entire**
SQLite store (65 MB on the reference book), and atomically replaces the
document — all synchronously. ⌘S and every autosave tick can beachball the UI
for the duration.

**Fix.** Move the write off the main actor (snapshot value state or serialize
against edits), show a subtle "Saving…" indicator in the toast layer, keep the
atomic replace. Incremental/dirty-row persistence is the deeper option if the
numbers still demand it (Phase 3).

## 3. Progress-feedback inventory

| Operation | Today | Required |
|---|---|---|
| Match Attachments (OCR+AI batch) | determinate bar + cancel ✓ | — |
| Auto-Categorise: AI suggest / Read Attachments | per-batch counts ✓ | honest spinner during corpus build (P6) |
| Update Prices (`updatePriceHistory`) | text status, sheet-only | **determinate bar** (n of N securities) in sheet; completion toast (usability 6.8); Up-next row shows progress |
| Smart Import PDF extraction | per-page progress ✓ | — |
| Reports: capital gains, lots, advanced portfolio, forecast, transaction, reconcile | **none — UI freezes** | spinner placeholder + async (P3) |
| Period-End Close preview | none | spinner + async (P3) |
| Report commentary / forecast insights (AI) | async, needs visible spinner state check | ensure ProgressView while awaiting |
| Book open | determinate ✓ | — |
| Save / autosave | silent | brief toast on manual save failure only |
| FX live-rate fetch | button spinner ✓ | — |

### Verified fine (checked, no action)

- `AmountFormat` — Foundation `FormatStyle` (cached internally), no per-cell
  formatter allocation.
- `AppDateFormat` — locked one-formatter-per-pattern cache.
- Startup reopen — async with determinate progress.
- Sidebar (559 rows) — OutlineGroup with cheap rows; fine at this scale.

## 4. Measurement (before/after, not vibes)

- `os_signpost` intervals around: `refreshAll`, `rebuildAccountTree`,
  `refreshRegister`, each report builder, `smartCategoryPlans`,
  `updatePriceHistory` — visible in Instruments' Points of Interest.
- DEBUG-only console timing for the same, so regressions show in normal runs.
- Acceptance on the reference book: register open <100 ms; click/selection
  body pass <16 ms; editor keystroke <16 ms; Capital Gains first build shows
  progress and UI stays interactive; subsequent opens instant (cache).

## 5. Plan integration

Merged into `usability-review.md` §7 as:

- **Phase 0.5 — performance quick wins** (before UI restructuring):
  P1 registerSummary snapshot · P2 suggestions cache · P4 postableAccounts
  cache · P5.2 dead-work skips · **P9 scoped undo snapshots** (biggest single
  win — kills the full-XML export on every price/rate/settings edit) ·
  signposts/timing harness.
- **Phase 2 additions**: P3 async reports + progress placeholders (rides with
  the toast layer and Update-Prices progress work) · P6 corpus off main ·
  **P10 async save with "Saving…" indicator**.
- **Phase 3 additions**: P5.4 incremental tree balances, P7 incremental
  journal, incremental persistence — *only if* the measured numbers say
  they're still needed.
