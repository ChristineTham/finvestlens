# P9 — Planning & insights: design

| | |
|---|---|
| **Status** | **Shipped, 24 Jul 2026** — all nine sections implemented as designed (see [implemented.md](implemented.md)); deviations noted inline |
| **Scope** | FR-PLAN-10/11/12/13/15/16/17, FR-GOAL-02, audit logging |
| **Companions** | [PRD](prd.md) · [Plan](plan.md) §13 · [Money study](enhancements-msmoney.md) · [Frollo study](enhancements-frollo.md) |

The governing principles, from the plan's own risk note and NG4:

1. **Transparent, adjustable models.** Every projection is a plain arithmetic
   model whose assumptions are visible and editable — never a black box.
2. **Not advice.** Planners and estimators are labelled as estimates from the
   user's own figures; nothing is presented as a recommendation.
3. **The book is the source.** Defaults are seeded from real book data
   (balances, income/expense averages, existing tax tags); the user adjusts.
4. **Deterministic first.** Plain-language summaries are template-generated
   from computed figures; Apple Intelligence may rephrase, but the existing
   `ReviewStoryValidator` regime applies (model proposes, validator disposes).

---

## 1. Debt Reduction Planner (FR-PLAN-10)

**Model.** A monthly simulation over the book's open liabilities:

- Each debt: current balance (from the book), **APR** and **minimum monthly
  payment** (user-entered — statements don't carry them; persisted per
  account).
- A **monthly debt budget** (user-entered, ≥ sum of minimums).
- Strategy: **avalanche** (highest APR first) or **snowball** (smallest
  balance first); the third view is **minimums only** — the baseline.
- Each month: interest accrues at APR/12 on the running balance; every debt
  receives its minimum; the entire remainder of the budget goes to the focus
  debt; when a debt closes, its payment rolls into the next (the "snowball").
- Outputs: per-debt payoff month; total months; total interest paid;
  **interest and time saved vs minimums-only**; balance-over-time series for
  the chart. Interest rounds to cents monthly (currency rounding, as the
  bank would).

Safety rails: a budget below the total minimums, or a debt whose minimum
doesn't cover its monthly interest, is flagged rather than simulated into
infinity (simulation caps at 100 years).

## 2. Lifetime Planner (FR-PLAN-11)

**Model.** An **annual** projection from the current year to a life-expectancy
horizon, over five buckets seeded from the book and adjustable:

| Bucket | Seeded from |
|---|---|
| Cash | bank/cash accounts |
| Investments | security accounts + their parents (market value) |
| Retirement | accounts under a retirement root (auto-detected by name — "SMSF"/"Super" — reassignable) |
| Property | fixed-asset accounts |
| Debts | liability/credit balances |

Assumptions (all editable, sensible defaults seeded from the book's last 12
months): salary + annual growth; living expenses + inflation; retirement age
and life expectancy; birth year; annual retirement contributions; return
rates (investments, retirement, cash, property — nominal, net of fees/taxes);
retirement spending as a share of pre-retirement expenses; pension/other
retirement income; **life events** (one-off amount in a year, positive or
negative — house, education, inheritance, downsizing).

Per working year: income grows; tax is estimated with the §3 bracket table;
savings = income − tax − expenses; positive savings go to investments (after
the retirement contribution goes to retirement); negative savings draw from
cash → investments. Per retired year: spending = retirement share × (inflated
expenses) − pension income, drawn cash → investments → retirement (super is
accessible by then); property appreciates but is not drawn (a life event can
model a downsize). Debts amortise with the §1 machinery's simple
interest+payment model. Everything is nominal; the chart offers a
**today's-dollars** toggle (deflate by cumulative inflation).

Outputs: net worth by bucket over time (stacked area), the **depletion age**
if liquid+investment+retirement funds run out, and a feasibility verdict
("your money lasts to age N with $X remaining" / "runs short at age N").

## 3. Tax estimator & tagging (FR-PLAN-12)

Tax-line **tagging** exists (account-level tax flags); the estimator reads it:

- **Assessable income**: FY-to-date totals of tax-relevant income accounts;
  franking (imputation) credits are grossed up and counted as an offset.
- **Deductions**: FY-to-date totals of tax-relevant expense accounts.
- **Capital gains**: the existing realised-gains machinery for the FY, with
  the >12-month discount share applied (editable, default 50% — AU).
- **Taxable income** = assessable + net capital gains − deductions.
- **Brackets**: an editable table (rate over threshold), seeded with
  Australian resident rates for the current FY (2026–27: 0% to $18,200, then
  15%, 30%, 37%, 45%) plus an optional levy percentage (default 2%,
  Medicare); the table is data, not law — the user edits it as rules change.
- **Withholding**: expense/equity accounts tagged as tax-withheld count as
  credits → the output is an **estimated refund or amount owing**.

The estimate screen shows every line with its source accounts, the bracket
arithmetic in full, and the standing disclaimer.

## 4. Insights & comparison (FR-PLAN-13)

A **Spending Insights** report: two periods side by side (this vs last month,
quarter, FY — or custom), per top-level expense/income category:

- current, prior, delta and % delta, share of spending;
- **top movers** (largest absolute increases/decreases);
- new and disappeared categories;
- a **plain-language summary** — deterministic template sentences built from
  the computed figures ("Spending rose 8% ($412), driven by Insurance (+$310)
  and Groceries (+$102); Dining fell $95.").

## 5. Financial wellbeing score (FR-PLAN-16)

Four transparent components, each 0–25, summing to 0–100, computed from the
last full three months against the prior three:

| Component | Measure | Full marks at |
|---|---|---|
| Savings rate | (income − spending) / income | ≥ 20% |
| Cash buffer | liquid balance / monthly essential spend | ≥ 6 months |
| Debt pressure | non-mortgage debt / annual income | 0% (0 marks ≥ 60%) |
| Spending trend | this-3-months vs prior-3-months spending | flat or falling |

Each component scales linearly between its floor and target, and the detail
view states the exact inputs ("liquid $58k ÷ essential spend $6.2k/mo = 9.4
months"). Surfaced as a dashboard tile with the breakdown one click away.

## 6. Financial summary "passport" (FR-PLAN-17)

A curated, **user-initiated** PDF: book title + date; net worth figure and
12-month trend; assets and liabilities by class; income, expenses, and
savings rate over the last 12 months. Built with the existing statement
typography and `ReportExport` PDF machinery. Nothing leaves the machine
except the file the user saves.

## 7. Savings challenges (FR-GOAL-02)

A challenge decorates an existing savings goal: name, target amount, start
and end dates. Progress = the goal's allocation growth since the start,
measured against the straight-line pace to the target; states are **ahead /
on track / behind / done / lapsed**. Surfaced with the goals UI and in Up
Next when a challenge is behind or ending soon. Stored with the goals in the
book's KVP.

## 8. Emergency Records Organizer (FR-PLAN-15)

A structured records area — kinds (insurance, account, contact, document,
other), each with a title, free key/value detail rows, notes, and optional
links to the existing attachment system. Stored in the book (KVP), so records
travel with the file and its backups. The screen can require **local
authentication** (Touch ID / password) each time it is opened — a view gate,
honestly described: the data's protection at rest is the book file's.

## 9. Audit log

GnuCash-style sidecar: an append-only `<book>.audit.log` beside the document
records one line per edit operation (timestamp, operation name, transaction
count) — written on the same code path as undo registration, so it can't
drift from reality. A Tools window shows the tail. The log never enters the
book file and rotates at a size cap.

---

## Decisions

- **AU defaults, editable everywhere.** Bracket tables, levy, CG discount,
  super accessibility are data with AU seed values, not hardcoded law.
- **Annual granularity for Lifetime, monthly for Debt** — matches the
  precision each question deserves; both models are pure functions in
  `FinvestLensReports` with fixture tests.
- **No Monte Carlo.** Single deterministic path with adjustable assumptions;
  uncertainty is communicated by editing assumptions, not simulated fans.
- **Wellbeing thresholds are constants in one table** (this document + code
  comment), chosen from common guidance (20% savings rate, 3–6 month buffer);
  they are presentation, not advice.
