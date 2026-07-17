# Reports: design

*17 Jul 2026 — written after auditing GnuCash's catalogue and reviewing our own
module; this design replaces the surface before its shape gets replicated
across fifteen report kinds.*

## What the review found

The arithmetic is good — every report is pinned to an identity (trial balance
columns agree, equity statement bridges two balance sheets, cash flow's in −
out equals the set's net change) and verified against the reference book. The
*surface* has five structural problems:

1. **Detached window / modal.** Reports open in their own window (macOS) or a
   sheet (iOS). An analytics surface should live where the data lives — the
   detail pane — and the window has proven fragile even to automate: it opens
   behind, resists positioning, and can be opened twice.
2. **Pregeneration.** Opening Reports immediately computes the default report.
   On a 46,553-transaction book that is seconds of work the user did not ask
   for, before they have even said which report they want.
3. **Recompute-in-body.** Every report computes inside SwiftUI `body`, so it
   recomputes on *every UI tick* — a date-picker interaction recomputes a
   full-book report per keystroke. This is most of the perceived slowness.
4. **O(accounts × transactions) arithmetic.** The statement reports ask each
   account for its balance, and every balance walks the whole book: 559 × 46k
   ≈ 26M split visits per computation. This is exactly the shape of the
   `netWorthSeries` bug (32.3s → 0.066s when rewritten as one pass).
5. **No period vocabulary, no configurations, register-grade rendering.**
   Dates were hard-coded (now ad-hoc pickers); there is no financial-year
   selector, no default period, and no saved configurations even though
   FR-RPT-04 promises them. Rendering is plain `List` rows — a report reads
   like another register, when it should read like an annual report.

## Decisions

**1. Inline first.** Reports is a *destination in the main window's detail
pane*, entered from the Book menu / toolbar (⌘R) like the Dashboard. "Open in
New Window" remains as an explicit, secondary command. Selecting an account in
the sidebar leaves reports mode — the sidebar always answers "show me this
account".

**2. A gallery, not a report.** Entering Reports shows a chooser: saved
favourites first, then the catalogue grouped (Statements / Activity /
Investments). *Nothing computes until a report is chosen*, and each report
screen computes only when its parameters settle (`.task(id: configuration)`),
with a progress indicator — never in `body`.

**3. One parameter model.**
- `ReportPeriod` — the timescale vocabulary: current/previous **financial
  year**, calendar year to date, previous year, quarter, month, last 12
  months, all time, custom range. Resolved against a financial-year start
  month, since books keep FY conventions (Australia: July–June).
- `ReportConfiguration` (Codable) — kind + period + account scope + depth.
- **Favourites**: named configurations saved in the book's KVP
  (replace-by-name, like saved find queries). FR-RPT-04, finally honoured.
- **Defaults in Document Settings** (book KVP): FY start month — defaulting
  to July when the book's base currency is AUD, else January — and the default
  period for a freshly opened report (default: current financial year). No
  slot is written until the user changes a value.

**4. One-pass arithmetic.** `Book.balancesByAccount` gains date bounds; every
statement report is rewritten to one book walk plus one conversion per
account. Identities and totals are already pinned by the report tests, which
double as the equivalence proof. Measured before/after on the reference book.

**5. Reports look like documents.** A shared scaffold: header (title, period,
book), a KPI callout row (the two-to-four numbers the report exists to
produce), a chart where one is meaningful, `Grid`-based tables with aligned
numerals, rules and bold totals, and a notes area — fixed methodology notes
("securities valued at market as of …") plus optional Apple Intelligence
commentary following the `ForecastNarrator` pattern: deterministic facts in,
short grounded observations out, absent when Intelligence is unavailable.

## Non-goals (for now)

- Rebuilding the investment reports' internals — they render inside the new
  navigation and chrome; their bodies migrate to the scaffold later.
- Scheme-style report plugins. The catalogue is code.
- PDF parity with the on-screen document (export keeps the printable-statement
  path; unifying it with the scaffold is follow-up work).
