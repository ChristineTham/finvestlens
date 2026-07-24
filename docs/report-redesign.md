# Report Redesign — Annual-Report Statements & the Financial Review Deck

| | |
|---|---|
| **Document status** | Implementation plan v1.0 |
| **Date** | 2026-07-24 |
| **Scope** | Elevate the statement reports to annual-report presentation quality, and add a CFO-style "Financial Review" slide deck with charts and on-device insights |
| **Companions** | [PRD](prd.md) (FR-RPT-*) · [Architecture](architecture.md) §10/§11 · [Implemented](implemented.md) |

> **Status (24 Jul 2026): implemented** — S1–S4 shipped (commits
> "Annual-report statements…" and "Financial Review deck…"); 397 tests green
> incl. statement identities and the story validator; verified on the
> reference book by screenshot (statement face + notes; deck slides). One
> hardening beyond the plan: the narrator's output passes a **deterministic
> number validator** — any story quoting a figure not in the slide's facts
> pack is rejected (the live model invented YoY percentages on first run;
> the validator now makes that impossible to ship).

## 1. The brief

The report *arithmetic* is verified to the cent against GnuCash; the report
*presentation* is not at publication standard. Two symptoms:

1. **Raw account paths on the face of statements.** A line like
   `Income:Distributions:VGAD:Distribution` belongs in a working paper, not a
   financial statement. Annual reports present the chart of accounts
   **hierarchically**, make **judgement calls** about what earns a line on the
   face of the statement, and push detail into **notes**.
2. **No presentation layer.** Financial results are also *presented* — a CFO
   walks investors through a deck where each slide carries one message, a
   chart, callouts, and an insight. The app has the data and the on-device
   model to do this; it only renders tables.

## 2. Research basis

Conventions adopted, with sources:

**Statement structure (IAS 1 / ASC 274).**
- The face of a statement carries **material classes of similar items**;
  immaterial items are aggregated; detail is disclosed in **notes** that
  follow the order of the face and cross-reference it
  ([IFRS Community: IAS 1](https://ifrscommunity.com/knowledge-base/ias-1-presentation-of-financial-statements/),
  [Grant Thornton IAS 1 factsheet](https://www.grantthornton.com.au/globalassets/1.-member-firms/australian-website/technical-publications/ifrs/gtal_2016_factsheet-ias1-presentation-of-financial-statements.pdf)).
- For a **personal** book the right frame is the AICPA/FASB **personal
  financial statements** model (ASC 274): a *Statement of Financial
  Position* with **assets in order of liquidity** and **liabilities in order
  of maturity** (no current/non-current split), assets at **estimated
  current value**, plus a *Statement of Changes in Net Worth*
  ([Wiley GAAP ch. ASC 274](https://onlinelibrary.wiley.com/doi/10.1002/9781119541882.ch13),
  [Accountant Town: ASC 274 presentation](https://www.accountanttown.com/fasb/presentation/personal-financial-statements/)).

**Statement typography.**
- Figures right-aligned in tabular numerals; a **single rule above a
  subtotal**, a **double rule under the final total**; the currency symbol on
  the **first figure of a column and on totals only**; negatives in
  **parentheses** ([Accounting Insights: double underline](https://accountinginsights.org/how-to-apply-a-double-accounting-underline-format/),
  [AccountingWare: statement formatting](https://accountingware.com/activreporter/blog/formatting-best-practices-for-financial-statements),
  [Opinionated guide to statement formatting](https://blog.techaccountingpro.com/p/opinionated-guide-on-financial-statement)).
- Label hierarchy by indentation; a slim **Note** reference column between
  label and figures; comparative prior-period column as standard.

**Deck design (investor-relations practice).**
- **One message per slide**; the title states the conclusion ("Strong free
  cash flow supports continued investment"), never a topic label ("Cash
  flow"); 5–10-word headlines, ≤3 supporting points, minimal labelled
  charts; a key-messages/highlights slide up front
  ([Verdana Bold: investor presentation design](https://www.verdanabold.com/post/investor-presentation-design-how-visual-clarity-builds-investor-confidence),
  [Ink Narrates: IR deck guide](https://www.inknarrates.com/post/ir-presentation),
  [Tosea: earnings deck structure](https://tosea.ai/blog/earnings-call-presentation-deck-guide-2026)).

## 3. Design

### 3.1 The statement model (face + notes)

A new presentation layer sits **on top of** the verified engine reports —
the engine's flat `ReportLine`s (account GUID + amount) stay the single
source of arithmetic; the layer only *arranges* them.

```
Statement
 ├─ title / entityName / periodLabel / currencyCode / columns ["2026","2025"]
 ├─ sections: [StatementSection]           — the face
 │    └─ items: [StatementItem]            — caption · noteRef? · amounts ·
 │                                           children (≤1 level on the face) ·
 │                                           role (line | subtotal | total)
 └─ notes: [StatementNote]                 — number · title · hierarchical
                                             rows to leaf detail · total that
                                             ties to its face line
```

**Judgement rules (the "CFO calls"), in order:**

1. **Group by the user's own top-level structure.** The face of each section
   shows the *children of the category root* (e.g. under Income:
   Distributions, Dividends, Salary…), each as one caption with its subtree
   total. The user's tree *is* the classification; we present it, we don't
   invent one.
2. **Liquidity / maturity ordering (ASC 274).** Asset captions order by a
   liquidity class derived from the dominant account *type* in each subtree
   (cash & equivalents → brokerage/investments → receivables → other/property);
   liability captions by maturity proxy (credit cards → loans → other).
   Income/expense captions order by magnitude, descending.
3. **Collapse trivial chains.** A single-child chain
   (`Distributions ▸ VGAD ▸ Distribution`) collapses to its meaningful
   ancestor — no caption ever reads as a colon path.
4. **Small sections stay on the face.** If a caption's subtree has ≤ 3
   postings-bearing descendants, its children render as indented face lines
   instead of a note — a note with two rows is ceremony.
5. **Materiality folding.** Within a section, captions smaller than 2% of
   the section's absolute total fold into **"Other …"** (with a note listing
   them). The face of a section never exceeds ~10 captions.
6. **Notes carry the detail.** Every caption with folded detail gets a
   sequential note number. Note 1 is always *Basis of preparation*
   (auto-written: valuation at market via the price DB, report currency,
   rounding, the local-time date convention). Notes then follow face order,
   each a full hierarchical breakdown to leaf accounts whose total **ties to
   the face line** — enforced by tests.
7. **Comparatives by default.** Statements render a prior-period column
   (prior FY / prior year-end) when the book has data there; blank cells
   where an item didn't exist.
8. **Names, not paths.** Captions use the account's own name, title-cased as
   entered; the full path appears only inside notes as secondary detail.

**Statement titles** (personal-statements vocabulary): *Statement of
Financial Position* (balance sheet), *Income Statement* (kept — universally
read), *Statement of Changes in Net Worth* (equity statement). The Financial
Year Pack adopts the same builders automatically.

### 3.2 Statement rendering (screen + PDF)

A dedicated `StatementView` (and matching PDF renderer) replacing the
generic grid for statement kinds:

- Centered masthead: entity name (book name), statement title, period line,
  "All amounts in AUD" units line — the annual-report opening page.
- Columns: caption · **Note** · current period · prior period. Right-aligned
  tabular numerals; negatives in parentheses; currency symbol on first row
  and totals only.
- Rules: hairline **above subtotals**, **double rule** below section and
  statement totals. No zebra striping — statements use whitespace, not
  stripes.
- Type hierarchy: section headers small-caps semibold; captions regular;
  face children indented + smaller; subtotals medium; grand totals semibold.
  Sizes step down from the app's body font (the statement reads denser than
  UI chrome, as print does).
- Notes render after the statements as **Notes to the financial
  statements** — numbered, titled, hierarchical, each ending in a ruled
  total that ties back.
- PDF: identical content through the existing printable pipeline, upgraded
  with the same typography (multi-page capable).

### 3.3 The Financial Review deck

A new surface — **Financial Review** — presented as a set of 16:9 cards,
each built like one slide of a CFO's results presentation:

```
ReviewSlide
 ├─ kicker      — section label ("SPENDING")
 ├─ headline    — the action title: states the conclusion, 5–12 words
 ├─ chart       — one focused, labelled chart (bar/donut/waterfall/line/gauge)
 ├─ callouts    — 2–4 big numbers with label and Δ vs prior period
 ├─ insight     — 1–2 sentences, Apple Intelligence (deterministic fallback)
 └─ footnote    — method line ("Prior period: FY 2024–25")
```

**The slide catalogue** — each slide appears **only when it has meaningful
data** (the dashboard's content-aware rule, applied here):

| # | Slide | Chart | Appears when |
|---|---|---|---|
| 1 | Title & highlights | KPI strip (net worth, net surplus, savings rate, return) | always |
| 2 | Net worth bridge | **Waterfall**: opening → +income → −expenses → ±market/FX → closing | closing ≠ opening |
| 3 | Income analysis | Bar by source + prior-period overlay | income ≠ 0 |
| 4 | Spending analysis | Top categories bar + Δ | expenses ≠ 0 |
| 5 | Savings & cash flow | Monthly net-flow columns + savings-rate line | ≥ 2 months of flows |
| 6 | Portfolio performance | Return + allocation donut, winners/losers | holdings exist |
| 7 | Dividends & franking | Stacked franked/unfranked + credits | dividend income ≠ 0 |
| 8 | Capital gains | Realised gains by security | disposals in period |
| 9 | Financial position | Assets vs liabilities composition; liquidity months; debt ratio | always (with a book) |
| 10 | Commitments & outlook | Scheduled outflows ahead; forecast trough | scheduled txns exist |

**Headlines and insights.** Every slide computes a deterministic **facts
pack** (numbers only, ranked, with prior-period deltas). The action title
and insight are produced from those facts by the on-device model (a new
`ReviewNarrator` in the Intelligence package, `@Generable` output: headline
≤ 12 words + 1–2 insight sentences, grounded ONLY in the given figures — the
established "model proposes, deterministic code disposes" contract, gated on
availability). **Fallback:** with Apple Intelligence off, a deterministic
composer writes the headline from the facts ("Net worth up 8.2% to $3.83m")
— the deck never degrades to empty titles.

**Navigation & export.** Horizontal paging with keyboard arrows and a page
dot/thumbnail strip; every slide is also exportable as a **landscape PDF
deck** (one slide per page) through the existing PDF machinery.

**Surfacing.** A hero card in the Reports gallery (peer of the Financial
Year Pack), a Reports-menu item, and a period selector driven by the same
`ReportPeriod` vocabulary. Slides recompute per (period, book revision)
through the report memo cache; insights generate lazily per slide and cache
on the same key.

## 4. Architecture

```
Reports package (engine arithmetic — unchanged, stays verified)
FeatureUI
 ├─ Statements.swift          Statement/StatementItem/StatementNote +
 │                            StatementBuilder (judgement rules 1–8; pure,
 │                            testable: inputs = engine report + account tree)
 ├─ StatementView.swift       annual-report rendering (screen)
 ├─ StatementPrint.swift      the same statement to paginated PDF
 ├─ FinancialReview.swift     ReviewSlide model + slide builders (facts packs,
 │                            dynamic selection) + deterministic headlines
 ├─ FinancialReviewView.swift 16:9 cards, paging, export
Intelligence
 └─ ReviewNarrator.swift      @Generable headline+insight from a facts pack
```

- `StatementBuilder` needs the account tree; it reads the `Book` on the main
  actor like every report builder, and memoises through `cachedReport`.
- The deck reuses existing computations (income statement, balance sheet,
  capital gains, portfolio, forecast, dividend classification from the FY
  pack) — no new arithmetic, only new arrangement. The net-worth bridge's
  *market/FX movement* term is derived as the balancing figure
  (closing − opening − income + expenses), labelled as such.

## 5. Implementation phases

**S1 — Statement model + builder (+ tests).**
`Statement`/`StatementBuilder` with rules 1–8; identity tests on the
reference book: face totals ≡ engine totals; every posting-bearing leaf
appears exactly once (face or note); note totals tie to their face lines;
folding conserves sums; chain-collapse produces no path-like captions.

**S2 — Statement rendering.**
`StatementView` + PDF; route Statement of Financial Position, Income
Statement, and Statement of Changes in Net Worth through it (gallery + FY
pack); comparative columns; masthead; notes section. Visual verification on
the reference book at screen and PDF.

**S3 — Financial Review deck (deterministic).**
Slide model, builders, dynamic selection, charts (incl. the waterfall),
callouts with deltas, deterministic headlines, paging UI, gallery/menu
surfacing, landscape PDF export.

**S4 — Intelligence layer.**
`ReviewNarrator` (headline + insight per slide, cached per revision),
availability gating and fallbacks, then a full-suite + both-platform pass
and visual verification of the deck on the reference book.

Each phase ships independently: build both platforms, run the suite, commit,
relaunch (standing workflow).

## 6. Non-goals & guardrails

- **No arithmetic changes.** The presentation layer arranges verified
  figures; identity tests enforce that nothing moves.
- **No invented numbers in AI output.** Headlines/insights are grounded in
  the facts pack; the deterministic fallback must always exist.
- **No advice.** Insights describe what happened, never what to do (NG4).
- The trial balance and working reports (transactions, reconciliation,
  lots…) keep their current tabular rendering — they are working papers,
  and that is the correct register for them.
