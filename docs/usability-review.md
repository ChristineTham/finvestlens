# Usability Review & Redesign Plan

*Reviewed at HEAD (July 2026), macOS-first, against the persona and journey below.*

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

## 4. Findings

Severity: **P0** blocks/derails the journey · **P1** real friction each visit ·
**P2** polish/consistency.

### Toolbar & command surfacing

- **F1 (P0) Toolbar overflows behind `»`.** The window toolbar carries two
  menus (New, Import), a Reconcile button, a Saved Searches menu, the search
  field, plus view-scoped items (Dashboard's period selector). At common
  window widths macOS collapses the tail behind the chevron — and what
  collapses first is exactly the monthly workflow (Import menu, Saved
  Searches). *HIG: a toolbar should hold few, high-frequency items; overflow
  is a signal of misplaced commands.*
- **F2 (P0) The monthly close has no home.** Import / Match Attachments /
  Auto-Categorise live inside a toolbar *menu* (two clicks, hidden when
  collapsed) and in the Book menu; Reconcile is a lone toolbar button that's
  disabled until an account is selected, with no hint why. The journey's most
  important sequence is invisible: nothing on screen says "you have 43
  uncategorised transactions and 12 unmatched documents; VISA was last
  reconciled 34 days ago."
- **F3 (P1) Reconcile is account-scoped but placed globally.** A window-level
  button that's usually disabled reads as broken. It belongs with the account
  (register toolbar / sidebar context), and its disabled state should explain
  itself.
- **F4 (P2) Saved Searches doesn't earn toolbar rank.** Rarely used, two-level
  menu. Belongs inside the search experience itself (suggestions under the
  search field), freeing a slot.

### Register

- **F5 (P1) The style switcher is nonstandard and resets.** An in-content
  strip hosts a label-less segmented control (Basic/Auto-Split/Journal) plus
  five more controls. HIG places view options in the window toolbar (cf.
  Finder's view switcher) or the View menu; a custom strip above a table reads
  as content, costs 30pt of every register, and the choice is `@State` — it
  silently resets to Basic on every navigation.
- **F6 (P1) Register controls sprawl.** Subaccounts, Double Line, Attachments,
  Sort, Filter, Edit-selection — six discrete controls of mixed kinds. Finder
  solves the same problem with one **View Options** popup + dedicated
  Sort/Filter buttons.
- **F7 (P2) The entry bar is easy to miss.** GnuCash users look for the blank
  row; new-transaction affordance at the bottom is right, but nothing draws
  the eye to it (no prompt when the register is empty, no ⌘N hint).

### Dashboard

- **F8 (P1) Cards clip at the window's bottom edge.** The masonry's last row
  can render partially under the window edge with no way to scroll it fully
  into view (bottom content margin/safe-area handling).
- **F9 (P1) The glance doesn't lead to action.** The dashboard reports state
  but offers none of the journey's verbs: no "update prices" (or when they
  were last updated), no uncategorised count, no reconcile staleness, no
  unmatched documents. The persona opens the app *to do these things*.
- **F10 (P2) Panel priority is fixed.** The masonry shows panels by hardcoded
  priority; the persona can't demote Goals or promote Performance.

### Prices (UC2)

- **F11 (P1) "Update prices" is three navigations deep.** Sidebar ▸ Prices &
  Quotes ▸ Get Quotes sheet ▸ button. For a task done at nearly every visit it
  should be one click (toolbar/dashboard) with a visible "last updated"
  timestamp and inline progress; the existing `quoteStatus` never surfaces
  outside the sheet.

### Reports (UC5, UC10)

- **F12 (P1) No shortcut to "my" reports.** Every visit re-navigates the full
  catalogue. No recents, no favourites.
- **F13 (P2) No EOFY bundle.** Year-end means manually running 3–4 reports
  with the same period. A one-click "Financial Year Pack" (P&L, capital gains,
  dividend/franking summary, balance sheet) with export would close UC10.

### Menus & keyboard

- **F14 (P2) The Book menu is a grab-bag** (imports, AI tools, navigation,
  book maintenance). Standard split: File = book & import I/O; View = register
  style/appearance; Transaction; Book = maintenance (scrub, close, tax);
  Reports gets its own menu.
- **F15 (P2) Shortcut gaps.** No ⌘R (reconcile), ⌘⇧U (update prices), ⌘⇧M
  (match attachments). ⌘1/⌘2… don't jump to sidebar destinations.

### Feedback & state

- **F16 (P1) Long operations lack ambient feedback.** Quote refresh, import,
  match, categorise each report progress only inside their own sheet; finish
  states (`infoMessage`, `quoteStatus`) mostly vanish. One consistent,
  non-modal toast/status surface is missing.
- **F17 (P2) Disabled controls rarely say why** (Reconcile, Intelligence
  features do via `.help`, but discoverability of tooltips is low).

---

## 5. Redesign — target shape

**Principle: the window shows the journey.** Global toolbar = create, import,
search. The register owns its account-scoped tools in the standard place. The
dashboard opens the visit with *state + the verbs that act on it*.

### 5.1 Window toolbar (fixes F1–F4)

```
[+ New ▾]   [⬇ Import ▾]                    …view-scoped items…   [🔍 Search]
```

- **New ▾** and **Import ▾** menus as today (Import keeps Bank File / Smart
  Import / Match Attachments / Auto-Categorise).
- **Reconcile moves out** (see 5.2). **Saved Searches moves into search**
  (suggestions menu when the field is focused / bookmark glyph inside it).
- Register/Dashboard contribute their own compact view-scoped items. Nothing
  overflows at ≥800pt.

### 5.2 Register toolbar (fixes F3, F5, F6)

When a register is showing, it contributes toolbar items (in-content strip
deleted; table gains the space):

```
[Basic | Auto-Split | Journal]   [⚙ View ▾]   [↕ Sort ▾]  [▽ Filter]  [✓ Reconcile]  [✎ Edit]
```

- Style switcher: toolbar segmented control, **persisted** (`@AppStorage`).
- **View ▾** popup: Double Line, Subaccounts, Attachments panel.
- **Reconcile** lives here — always enabled because a register *is* an
  account. (Also stays in the account's sidebar context menu.)
- **Edit** enabled on selection (single → inspector, multi → Bulk Edit), as
  the current discreet button.

### 5.3 Dashboard "Up next" card + status (fixes F2, F9, F11, F16)

A first-position card built from live model state:

```
Up next
• Prices updated 3 days ago              [Update Prices]
• 43 uncategorised transactions          [Categorise…]
• ANZ VISA last reconciled 34 days ago   [Reconcile]
• Import this month's statements         [Import…]
```

Rows appear only when actionable (all clear → "You're up to date ✓").
`quoteStatus` progress shows inline on the row. This gives the monthly close a
visible home without adding chrome anywhere else.

### 5.4 One-click prices (F11)

- **Update Prices** action = the existing gap-filling `updatePriceHistory`,
  invoked from the Up-next row, a toolbar item on Prices, and **⌘⇧U**.
- Last-updated timestamp derived from the price DB; progress via the row +
  a toast on completion ("Added 214 prices · 2 failed — details").

### 5.5 Reports recents + EOFY (F12, F13)

- ReportsHome gains **Recents** (last 5 opened, persisted) at the top.
- **Financial Year Pack**: one click runs P&L, Balance Sheet, Capital Gains,
  Dividend/Franking summary for the chosen FY into one scrollable/printable
  view with per-report export.

### 5.6 Menus & shortcuts (F14, F15)

- **File**: New/Open/Save…, Import Bank File…, Smart Import…, Export.
- **View**: register style (⌘1/2/3 within register), Double Line, Attachments,
  Text Size, sidebar destinations (⌥⌘1…).
- **Transaction** unchanged. **Book**: Auto-Categorise, Match Attachments,
  Update Prices (⌘⇧U), Scrub, Close Book, Tax Options.
- **Reports** menu listing the catalogue + Recents.
- Shortcuts: ⌘R Reconcile (register), ⌘⇧U prices, ⌘⇧M match, existing ⌘E/⌘D…

### 5.7 Feedback layer (F16, F17)

- A single **toast/status overlay** at the window's bottom-trailing corner
  driven by `model.infoMessage`/`quoteStatus`-style events: operation started
  / progress / finished / failed (with a details affordance). All long
  operations route through it; sheets keep their local progress too.

### 5.8 Dashboard fixes (F8, F10)

- Fix bottom clipping (content margins / safe-area on the masonry scroll).
- Long-term (P2): per-user panel show/hide + order via a "Customise…" popover;
  persisted like the period.

---

## 6. Implementation plan

### Phase 1 — the visible pain (P0/P1 structural)
1. **Toolbar restructure** (5.1): trim window toolbar; move Saved Searches
   into search suggestions; delete Reconcile from the global bar.
2. **Register toolbar** (5.2): style switcher + View popup + Sort/Filter/
   Reconcile/Edit as toolbar items; delete the in-content strip; persist style.
3. **Dashboard Up-next card** (5.3) with the four journey rows + model
   counts (uncategorised count, last-reconcile ages, last price date).
4. **Dashboard bottom clipping fix** (F8).

### Phase 2 — journey accelerators (P1)
5. **One-click Update Prices** everywhere + last-updated + completion toast.
6. **Toast/status overlay** and route quote/import/match/categorise
   completions through it.
7. **Reports Recents** (persisted) on ReportsHome.
8. **Menu bar restructure + shortcut pass** (5.6).

### Phase 3 — depth (P2)
9. **EOFY Financial Year Pack** view with export.
10. **Dashboard customisation** (hide/reorder panels).
11. Register empty-state prompt for the entry bar; disabled-state explanations
    inline (not only tooltips); iPad layout audit of the new toolbar.

Each step ships independently: build both platforms, commit, relaunch for
visual verification (standing workflow).

---

## 7. Out of scope (noted, not forgotten)

- Multi-window / tabs for side-by-side registers.
- iCloud sync; iOS phone layout (iPad compiles today).
- Localisation audit (date-format preference already user-set).
