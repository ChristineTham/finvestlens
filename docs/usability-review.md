# Usability Review & Redesign Plan

*Reviewed at HEAD (July 2026), macOS-first, against the persona and journey
below. Second pass adds a full functionality inventory (implemented but
unsurfaced / hard to reach) and a redundancy register (duplicates, dead code)
— audited by sweeping every public `AppModel` function for UI callers, every
`RootPanel` for entry points, and every account-picking site. Third pass:
`performance-review.md` (hot paths, progress-feedback inventory) — its fixes
are merged into the phases below as Phase 0.5 and Phase 2 items. Fourth pass
(§6A): with the constraint of GnuCash familiarity **explicitly dropped** — the
user actively dislikes the GnuCash UI — the register unifies into one view,
GnuCash jargon leaves the interface, and reconcile is reimagined.*

---

## 1. Persona

**Chris** — an experienced personal-finance keeper with a 20-year GnuCash book
(559 accounts, ~46k transactions, ~35 securities, multi-currency). Comfortable
with double-entry, not interested in fighting software. Uses one Mac, large
screen, keyboard-heavy habits. Values: correctness, speed to complete a chore,
nothing hidden.

## 2. User journey

| Cadence | Activity |
|---|---|
| **Weekly-ish** ("the glance") | Open the book → see current state (net worth, accounts, recent activity) → update security prices → enter a handful of transactions (cash, transfers) → maybe run one report. |
| **Monthly** ("the close") | Import bank/card statements → match scanned receipts & invoices to transactions → categorise everything new → reconcile each account against its statement. |
| **Yearly** ("EOFY") | Run income/expense, capital-gains and dividend/franking reports for the financial year → export for the tax return. |

## 3. Use cases

- **UC1 Glance** — open app, understand financial state in <10s.
- **UC2 Update prices** — bring all security prices current, see that it worked.
- **UC3 Enter transaction** — record a purchase/transfer in <15s.
- **UC4 Browse an account** — open a register, scan history, drill into a transaction.
- **UC5 Run a report** — open one of "my" reports for a period.
- **UC6 Import statements** — monthly bank/card files or PDFs in.
- **UC7 Match documents** — link the month's receipts/invoices to transactions.
- **UC8 Categorise** — clear the uncategorised backlog.
- **UC9 Reconcile** — tick off an account against its statement.
- **UC10 EOFY pack** — produce the year's tax-relevant reports.
- **UC11 Find** — locate a transaction by memory fragment ("that Bunnings run in March").
- **UC12 Fix a mistake** — edit/undo anything just done.

---

## 4. Usability findings

Severity: **P0** blocks/derails the journey · **P1** real friction each visit ·
**P2** polish/consistency.

### Toolbar & command surfacing

- **F1 (P0) Toolbar overflows behind `»`.** The window toolbar carries two
  menus (New, Import), a Reconcile button, a Saved Searches menu, the search
  field, plus view-scoped items (Dashboard's period selector). At common
  window widths macOS collapses the tail behind the chevron — and what
  collapses first is exactly the monthly workflow (Import menu, Saved
  Searches). *HIG: a toolbar should hold few, high-frequency items.*
- **F2 (P0) The monthly close has no home.** Import / Match Attachments /
  Auto-Categorise live inside a toolbar *menu* (two clicks, hidden when
  collapsed) and in the Book menu; Reconcile is a lone toolbar button that's
  disabled until an account is selected, with no hint why. Nothing on screen
  says "43 uncategorised transactions; VISA last reconciled 34 days ago."
- **F3 (P1) Reconcile is account-scoped but placed globally.** A window-level
  button that's usually disabled reads as broken. It belongs with the account.
- **F4 (P2) Saved Searches doesn't earn toolbar rank.** Belongs inside the
  search experience (suggestions under the field).

### Register

- **F5 (P1) The style switcher is nonstandard and resets.** An in-content
  strip hosts a label-less segmented control plus five more controls. HIG
  places view options in the window toolbar (cf. Finder) or the View menu; the
  strip costs 30pt of every register, and the style is `@State` — it silently
  resets to Basic on every navigation.
- **F6 (P1) Register controls sprawl.** Subaccounts, Double Line, Attachments,
  Sort, Filter, Edit-selection — six controls of mixed kinds. Finder's answer:
  one **View Options** popup + dedicated Sort/Filter buttons.
- **F7 (P2) The entry bar is easy to miss.** No prompt when the register is
  empty; no ⌘N hint.

### Dashboard

- **F8 (P1) Cards clip at the window's bottom edge** (bottom content
  margin/safe-area handling in the masonry scroll).
- **F9 (P1) The glance doesn't lead to action.** The dashboard reports state
  but offers none of the journey's verbs: no "update prices" / last-updated,
  no uncategorised count, no reconcile staleness, no unmatched documents.
- **F10 (P2) Panel priority is fixed** — no per-user show/hide or ordering.

### Prices & securities (UC2)

- **F11 (P1) "Update prices" is three navigations deep** (sidebar ▸ Prices &
  Quotes ▸ Get Quotes sheet ▸ button), with `quoteStatus` progress visible
  only inside the sheet and no "last updated" anywhere.
- **F11a (P1) SecuritiesView is buried treasure.** A full securities manager —
  watchlist (`addWatchSecurity`), **price targets that feed the dashboard
  Alerts card** (`setPriceTarget`), rename security, per-security history
  refetch — exists but is reachable only as a *sheet inside the Prices &
  Quotes destination*. The Alerts card shows targets firing, yet the place to
  set them is three levels deep and invisible. Promote to a destination (or
  first-class tab of Prices) and cross-link from the Alerts card.

### Reports (UC5, UC10)

- **F12 (P1) No shortcut to "my" reports** — no recents, no favourites (the
  22-report catalogue itself is complete).
- **F13 (P2) No EOFY bundle** — year-end means manually running 3–4 reports
  with the same period.

### Menus & keyboard

- **F14 (P2) The Book menu is a grab-bag** (imports, AI tools, navigation,
  maintenance). Split: File = I/O; View = register style/appearance;
  Transaction; Book = maintenance; Reports gets its own menu.
- **F15 (P2) Shortcut gaps.** No ⌘R (reconcile), ⌘⇧U (update prices), ⌘⇧M
  (match attachments); no ⌥⌘1… for sidebar destinations.
- **F15a (P2) Menu-only features.** Findable *only* via the menu bar: Find
  Account, Tax Report Options, **Linked Documents** (the monthly matching
  review!), Loan Calculator, Period-End Close. Linked Documents deserves a
  place in the documents workflow (Match Attachments sheet / Up-next card);
  the others are acceptable as menu items but should sit in the right menus.

### Feedback & state

- **F16 (P1) Long operations lack ambient feedback** — progress and
  completions (`quoteStatus`, `infoMessage`) confined to their sheets.
- **F17 (P2) Disabled controls rarely say why** beyond tooltips.

---

## 5. Functionality inventory (second-pass audit)

### 5A. Implemented but effectively hidden

| Capability | Where it lives | Verdict |
|---|---|---|
| Securities manager: watchlist, price targets/alerts, rename, refetch history | `SecuritiesView` behind a button-sheet inside Prices & Quotes | **Promote** (F11a) |
| Linked-documents roll-up (`linkedDocuments()`, `LinkedDocumentsView`) | Book menu only | **Cross-link** from Match Attachments + Up-next (F15a) |
| Price-target alerts feed | Dashboard Alerts card (read-only) | **Link** card → SecuritiesView to manage targets |
| Goal earmarking total (`earmarkedTotal`) | computed, never shown | **Show** "available less goals" on Goals card (P2) |
| Trading-account groundwork (`tradingAccount`) | model-only | Leave (deliberate; currency gain/loss is post-1.0) |
| Quote auto-refresh | wired at open ✓ but invisible | Show "auto-refresh on · last run" in Prices/Up-next |

### 5B. Dead code (no UI or internal callers — delete)

- `RecordCashPurchaseSheet` (superseded by editor `documentPrefill` flow)
- `applyCategoryAssignments` (superseded by `applyCategorization`)
- `backfillHistory(for:from:to:using:)` (superseded by `updatePriceHistory` /
  `refetchPriceHistory`)
- `journalEdgeRowID`, `journalEntryCount` (journal scroll now targets visible rows)
- `canDeleteAccount` (superseded by `deletionPlan`), `renameAccount`
  (superseded by `updateAccount`), `newDocument` (superseded by `newBook`),
  `accountID(ofSplit:)` (its picker was replaced)
- Audit leftovers on deletion: their tests move to the successors.

### 5C. Redundancy register (consolidate)

| Duplicate | Sites | Consolidation |
|---|---|---|
| **Account choosers — five patterns** | `AccountField`, `AccountPickerButton`, `AccountMatchPicker`, `StockTransactionSheet.accountPicker` (private 4th), **31 raw `Picker` sites** (Business, Import, SmartImport, TimeMileage, Reports, Parity, Goals-adjust, Dividend sheet, RecordCash…) | One family: `AccountField` (single-select forms), `AccountPickerButton` (table cells), `AccountMultiPicker` (multi-select, absorbing `AccountMatchPicker`). Kill all raw pickers and the private helper. |
| Two account-search algorithms | `AccountSearch.matches` (multi-term) vs `AccountMatchPicker.matching` (substring + placeholder rules) | One: `AccountSearch` gains `includePlaceholders`; sidebar filter and multi-picker use it (multi-term search everywhere). |
| Two pasteboard helpers | `GeneralPasteboard` (AttachmentsPanel) vs raw `NSPasteboard` in `TransactionClipboard` | One shared `Pasteboard` utility. |
| Two rate-recording APIs | `addExchangeRate` (PricesView) vs `recordFxRate` (editor) | One model API; the other becomes a thin alias or is removed. |
| `AccountMenuCell` | thin wrapper over `AccountPickerButton` | Inline and delete. |
| Settings bypasses the model | `PricingSettingsView` constructs its own `KeychainAPIKeyStore` instead of `model.apiKey/setAPIKey` | Route through AppModel (single source; availableProviders stays fresh). |
| Misplaced shared views | `EmbeddedQuickLook` + `GeneralPasteboard` live in AttachmentsPanel.swift; `LinkToTransactionSheet` lives in MatchAttachmentsSheet.swift but is used by the editor | Move each to its own file. |

---

## 6. Redesign — target shape

**Principle: the window shows the journey; one component per job.**

### 6A. Bold moves (GnuCash-familiarity constraint dropped)

**RD1 — One register, not three.** Basic/Auto-Split/Journal is GnuCash's
taxonomy, not a user need. Ship **one register**: today's Basic table where
selecting a transaction *expands its splits inline* (the Auto-Split behaviour
— already pixel-identical when collapsed). "Journal" becomes a **Show All
Splits** toggle in View options for the rare audit read. The style switcher —
segmented control, persistence question, layout-shift class of bugs — is
deleted outright. The whole-book journal stays as the sidebar's **All
Transactions** (né General Ledger).

**RD2 — De-GnuCash the language** (UI strings only; engine names and file
round-trip untouched). 11 jargon strings today:

| GnuCash-ism | Say instead |
|---|---|
| Imbalance-AUD / Orphan | **Uncategorised** |
| Scrub / Check & Repair | **Repair Book** |
| Placeholder (account) | **Group** |
| Double Line | **Show Details** |
| General Ledger | **All Transactions** |
| Auto-Split Ledger | *(gone with RD1)* |
| Num | **No.** |
| Period-End Close | **Close Financial Year** |

**RD3 — Reconcile, reimagined.** Statement-first (date + closing balance up
front — kept), then: **auto-clear runs immediately** as the opening move (its
result presented as "we matched 41 of 43 — review the 2 left"), a live
"difference remaining" figure as the headline, unmatched rows sorted to the
top, and Finish disabled-with-reason until zero. The magic-wand icon button
becomes the default path instead of an easter egg.

**RD4 — Entry without ceremony.** The register's entry bar gets a visible
prompt ("Add a transaction — press ⌘N"), ⌘N focuses it (⇧⌘N opens the full
split editor), and QuickFill's suggestion appears as inline ghost text rather
than a menu.

### 6.1 Window toolbar (F1–F4)

```
[+ New ▾]   [⬇ Import ▾]                    …view-scoped items…   [🔍 Search]
```
Reconcile moves to the register (6.2); Saved Searches folds into search
suggestions. Nothing overflows at ≥800pt.

### 6.2 Register toolbar (F3, F5, F6)

Register contributes toolbar items; the in-content strip is deleted:

```
[Basic | Auto-Split | Journal]  [⚙ View ▾]  [↕ Sort ▾]  [▽ Filter]  [✓ Reconcile]  [✎ Edit]
```
Style persisted (`@AppStorage`); View ▾ = Double Line, Subaccounts,
Attachments; Reconcile always enabled here; Edit adapts to selection.

### 6.3 Dashboard "Up next" card (F2, F9, F11, F16)

First-position card from live model state; rows only when actionable:

```
Up next
• Prices updated 3 days ago              [Update Prices]
• 43 uncategorised transactions          [Categorise…]
• ANZ VISA last reconciled 34 days ago   [Reconcile]
• Import this month's statements         [Import…]
```

### 6.4 One-click prices (F11) — `updatePriceHistory` from Up-next / Prices
toolbar / **⌘⇧U**, with last-updated from the price DB and completion toast.

### 6.5 Securities surfaced (F11a) — Prices & Quotes becomes a two-tab
destination (**Prices · Securities**) or Securities gets its own sidebar row;
dashboard Alerts card links to it.

### 6.6 Reports recents + EOFY (F12, F13) — Recents (last 5, persisted) atop
ReportsHome; **Financial Year Pack** (P&L, Balance Sheet, Capital Gains,
Dividend/Franking) with export.

### 6.7 Menus & shortcuts (F14, F15, F15a) — File/View/Transaction/Book/
Reports split; ⌘R, ⌘⇧U, ⌘⇧M, ⌥⌘1…; Linked Documents cross-linked from the
documents workflow.

### 6.8 Feedback layer (F16, F17) — one toast/status overlay, all long
operations route completions through it.

### 6.9 Dashboard fixes (F8, F10) — bottom clipping fix; later per-user panel
customisation.

---

## 7. Implementation plan

### Phase 0 — consolidation first (the audit's cleanups)
*Rationale: later phases touch every one of these surfaces; unify before moving.*
1. **One account-chooser family**: absorb `AccountMatchPicker` search into
   `AccountSearch`; convert all 31 raw `Picker` sites + the Stock sheet's
   private helper to `AccountField`/`AccountPickerButton`; delete
   `AccountMenuCell`.
2. **Delete dead code** (5B list) and move misplaced shared views to their own
   files (`EmbeddedQuickLook`, `Pasteboard`, `LinkToTransactionSheet`).
3. **Single rate API**; Settings pricing pane routed through the model.
4. Build + full test suite after each step.

### Phase 0.5 — performance quick wins (see `performance-review.md`)
*Register and editing must be super responsive before (and after) the UI moves.*
1. `registerSummary` becomes a per-refresh snapshot (kills 3 full-book scans
   per register click — P1).
2. Cached recency list for description suggestions (kills the 46k sort per
   editor keystroke — P2).
3. Cached `postableAccounts` (+ derived account lists) rebuilt with the tree
   (P4).
4. Dead-work skips in `refreshAll` (search only when active; batch-path
   coalescing audit — P5).
5. `os_signpost` + DEBUG timing harness; record before/after numbers on the
   reference book.

### Phase 1 — the visible pain (P0/P1 structural)
5. Toolbar restructure (6.1); Saved Searches → search suggestions.
6. **RD1: unify the register** — expandable-splits table as the only
   register; Show All Splits view option; delete the style switcher; register
   toolbar per 6.2 (View ▾ / Sort ▾ / Filter / Reconcile / Edit).
6a. **RD2: terminology sweep** (strings only) + RD4 entry-bar prompt & ⌘N.
7. Dashboard Up-next card (6.3) with live counts.
8. Dashboard bottom clipping fix (F8).

### Phase 2 — journey accelerators (P1)
8a. **RD3: reconcile reimagined** (auto-clear as the opening move, difference
    headline, review-the-remainder flow).
9. One-click Update Prices + **determinate progress** + last-updated + toast
   (6.4; perf §3).
10. Securities surfaced as a destination/tab; Alerts card links there (6.5).
11. Toast/status overlay; route quote/import/match/categorise completions (6.8).
12. **Async reports with progress placeholders** — capital gains, lots,
    advanced portfolio, forecast, transaction, reconcile, close-preview — via
    `cachedReport` + `.task` + `nonisolated` cores (perf P3); Auto-Categorise
    corpus off the main actor (perf P6).
13. Reports Recents (6.6a).
14. Menu bar restructure + shortcut pass (6.7).

### Phase 3 — depth (P2)
15. EOFY Financial Year Pack with export (6.6b).
16. Dashboard customisation (F10); earmarked-total on Goals card (5A).
17. Register empty-state prompt; inline disabled-state explanations; iPad
    audit of the new toolbar.
18. *(Only if Phase 0.5 numbers demand)* incremental account-tree balances and
    incremental journal rebuild (perf P5.4/P7).

Each step ships independently: build both platforms, run the test suite,
commit, relaunch for visual verification (standing workflow).

## 8. Out of scope (noted, not forgotten)

- Multi-window / tabs for side-by-side registers.
- iCloud sync; iPhone layout (iPad compiles today).
- Trading accounts / currency gain-loss ledger (deliberate post-1.0).
- Localisation audit (date-format preference already user-set).
