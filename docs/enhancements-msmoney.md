# Enhancement Study — Microsoft Money Plus (Sunset Edition)

| | |
|---|---|
| **Document status** | Draft v0.1 |
| **Last updated** | 2026-07-12 |
| **Purpose** | Evaluate Microsoft Money Plus features and decide which should enhance FinvestLens beyond GnuCash parity |
| **Companions** | [PRD](prd.md) · [Architecture](architecture.md) |

## Why look at Money

FinvestLens's baseline is GnuCash — rigorous **double-entry accounting**. Microsoft Money was a **consumer personal-finance** product whose strengths were the opposite end: **planning, forecasting, guidance, and approachability**. Money Plus (Sunset Edition) — the free, de-activated final release — added, over the Standard edition, three flagship tools (**Advisor FYI Alerts, Lifetime Planner, Debt Reduction Planner**) plus mature budgeting, cash-flow forecasting, and portfolio tools. These are largely **complementary** to GnuCash's engine: we keep the accounting rigor and layer Money's planning/insight experience on top.

## Feature-by-feature evaluation

Legend — **Adopt** (build it), **Later** (valuable, post-parity), **Skip** (already covered or out of scope). "GC?" = does GnuCash/our current PRD already cover it.

| Money feature | What it does | GC? | Verdict | Notes |
|---|---|---|---|---|
| **Advisor FYI Alerts** | Proactive home-page/notification alerts: bills due, projected low/negative balance, over budget, price targets hit, unusual spending, approaching limits | ✗ | **Adopt** | Excellent fit for Apple **notifications + widgets + Shortcuts**. A rules-driven alert engine over the engine. |
| **Cash-flow forecast + what-if scenarios** | Projects future account balances from scheduled bills/deposits; model a big purchase, income change, etc. and see the effect | partial (GnuCash has a static balance-forecast report) | **Adopt** | Interactive scenarios are the differentiator. Builds directly on scheduled transactions. |
| **Bills & Deposits / bill reminders + Financial Calendar** | Friendly recurring-bill tracker with due dates, pay/skip, and a calendar view | partial (we have scheduled txns) | **Adopt** | A UX layer on our SX model: due-date tracking, calendar, reminders. High everyday value. |
| **Advanced Budget (rollover / envelope)** | Category budgets with rollover of unspent amounts, budget-vs-actual, and forecasting to period end | partial (our budgets are basic) | **Adopt** | Extends `FR-BUD-*` with rollover/envelope semantics and projected end-of-period. |
| **Debt Reduction Planner** | Plan to pay off debts; order them, apply extra payments, see payoff date/interest saved (snowball/avalanche) | ✗ | **Adopt (Later)** | Self-contained planner over liability accounts. Popular, motivating feature. |
| **Lifetime Planner** | Long-range retirement/financial plan: income, expenses, assets, retirement accounts, taxes, inflation, and life events (house, education, retirement) → projected net worth over a lifetime, goal feasibility | ✗ | **Adopt (Later)** | Flagship differentiator; also the largest. Own module, post-parity. Data feeds from the engine. |
| **Portfolio Manager: watch lists, asset allocation, rate of return** | Track securities you don't own (watch lists), asset-allocation breakdown, performance / annualized return, cost basis | partial (GnuCash has portfolio reports + lots) | **Adopt** | Extends investments (`FR-INV-*`): watch lists, allocation view, ROR. Pairs with our quote providers. |
| **Tax tools: estimator, capital-gains estimator, tax-category tagging, deduction tracker** | Estimate tax liability, project capital gains, tag tax-related categories, track deductions; export to tax software (TXF) | partial (GnuCash: income-tax report + TXF export) | **Adopt (Later)** | Interactive estimator + tax-line tagging beyond a static report. TXF export already planned. |
| **Payee management + auto-categorization rules** | Payee list; rules that auto-rename and auto-assign category/account by payee on import | partial (our import matcher does statistical matching) | **Adopt** | Explicit, user-editable rules complement the matcher — big quality-of-life win for CSV/QIF/OFX import. |
| **Home dashboard + Net-worth-over-time front and center** | Customizable overview: balances, upcoming bills, budget status, net-worth trend, alerts | partial (we have a net-worth report) | **Adopt** | Natural SwiftUI home screen; surfaces alerts/forecast/budget/net-worth. Drives widgets. |
| **Insights / spending analysis / comparison reports** | Spending by category over time, period-vs-period comparisons, trends | partial (reports) | **Adopt (Later)** | Extends the reports gallery with trend/comparison and plain-language insights. |
| **Emergency Records Organizer** | Store important records: insurance, accounts, contacts, documents | ✗ | **Later / Could** | Nice but adjacent to accounting; a secure records area. Lower priority; risks scope creep. |
| **Home & Business: invoices, products/services, customer/vendor, time & mileage tracking, projects** | Small-business invoicing + time/mileage | mostly (GnuCash business features are in our P7) | **Skip / Fold-in** | Invoicing/customers/vendors already in `FR-BUS-*`. **Add mileage & time tracking** as small extras to P7. |
| **Setup Assistant / onboarding** | Guided first-run setup of accounts and categories | partial (`FR-COA-03` new-book assistant) | **Adopt** | Broaden the new-book assistant into a friendly onboarding flow. |
| **Online bill pay / online banking / MSN Money** | Live bank connections, bill pay, web content | ✗ | **Skip** | Already deferred/Won't (`FR-XIO-07`); dead services. |

## Recommendation summary

**Adopt now (fold into existing phases):**
- Advisor FYI-style **alerts** (P6, ties to notifications/widgets)
- **Cash-flow forecast + what-if scenarios** (P4/P5)
- **Bill reminders + Financial Calendar** over scheduled transactions (P4)
- **Budget rollover/envelope + projection** (P4)
- **Payee auto-categorization rules** (P4, with the import matcher)
- **Portfolio watch lists, asset allocation, rate of return** (P5)
- **Home dashboard** + net-worth trend (P6)
- **Onboarding assistant** (P4)
- **Mileage & time tracking** as Home-&-Business extras (P7)

**Adopt later (new phase — post-parity):**
- **Debt Reduction Planner**, **Lifetime Planner**, **Tax estimator/tagging**, **Insights/comparison reports** → **P9 — Planning & insights**

**Skip:** online bill pay/banking, MSN content, and business features already covered by `FR-BUS-*`.

## Positioning

These additions move FinvestLens from "a native GnuCash" toward "**GnuCash's rigor with Money's planning experience**" — a combination neither original offers on Apple platforms. The accounting engine stays the source of truth; every Money-inspired feature is a **read/projection or a guided workflow on top of it**, so none compromises double-entry integrity.

## References

- [Microsoft Money — Wikipedia](https://en.wikipedia.org/wiki/Microsoft_Money)
- [Lifetime Planner](http://msmoney.helpmax.net/en/financial-planning/about-the-lifetime-planner/) · [Advanced Budget](http://msmoney.helpmax.net/en/budget/about-the-advanced-budget/) · [Forecast available money](http://msmoney.helpmax.net/en/accounts/forecast-how-much-money-youll-have-available/)
- [Advisor FYI Alerts (overview)](https://microsoftmoneyoffline.wordpress.com/2025/03/02/take-advantage-of-the-advisor-fyi-alerts-feature-in-money-plus/)
- [Money Home & Business features](https://www.tekgia.com/software-for-business/268-microsoft-money-home-and-business.html)
- Project [PRD](prd.md) · [Architecture](architecture.md)
