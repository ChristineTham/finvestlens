# Enhancement Study — Frollo

| | |
|---|---|
| **Document status** | v1.0 — evaluation stands; delivery status below |
| **Last updated** | 2026-07-24 |
| **Purpose** | Evaluate Frollo's app features and decide which should enhance FinvestLens |
| **Companions** | [PRD](prd.md) · [Architecture](architecture.md) · [Money study](enhancements-msmoney.md) · [Firefly study](enhancements-firefly.md) |

> **Delivery status (24 Jul 2026).** The default category taxonomy +
> heuristic auto-categorisation shipped in P4 and is exceeded by the
> on-device Apple Intelligence layer (PDF import, per-line invoice
> categorisation, attachment matching). **Open Banking via CDR** remains
> **P8**; savings challenges, the financial wellbeing score, and the
> Financial Passport remain **P9**. (The Jul 2026 EOFY **Financial Year
> Pack** — one PDF of the annual-report statements, capital gains, and
> dividends & franking — and the **Financial Review deck**'s landscape-PDF
> export ([report-redesign.md](report-redesign.md)) are first steps toward
> the passport idea; see [implemented.md](implemented.md).)
| **Upstream** | [frollo.com.au/frollo-app](https://frollo.com.au/frollo-app/) |

## Why look at Frollo

[Frollo](https://frollo.com.au/) is an Australian personal-finance app and the country's leading **Open Banking (Consumer Data Right)** data provider. Unlike GnuCash (rigor), Money (planning), and Firefly III (automation), Frollo's centre of gravity is **connected data + engagement + financial wellness** for a consumer audience. Because FinvestLens is an **Australian** project, Frollo's most valuable contribution is a concrete answer to *how Australians connect their bank accounts*: the **CDR**, not the US/EU aggregators we noted for Firefly.

**Framing caveat.** FinvestLens is **local-first and private** — a document you own, on your disk/NAS/iCloud. Frollo is a **cloud aggregator**. So Frollo's connected-data features are adopted as **optional, clearly-consented, cloud-mediated add-ons**, never as a requirement; the core app keeps working fully offline with no account sharing.

## Feature-by-feature evaluation

Legend — **Adopt**, **Enhance** (upgrade a planned feature), **Later**, **Skip** (already covered). "Have?" = covered by current PRD.

| Frollo feature | What it does | Have? | Verdict | Notes |
|---|---|---|---|---|
| **Open Banking via CDR** | Link Australian bank/super/investment accounts through the **Consumer Data Right** — no password sharing, time-boxed consent | partial (bank sync planned via SimpleFIN/GoCardless) | **Adopt (Later)** | **The headline finding.** CDR is the AU-appropriate bank-sync path. Realistically integrated **via an accredited intermediary** (e.g. Basiq, or Frollo's CDR platform) rather than FinvestLens becoming an Accredited Data Recipient — a heavy regulatory bar. Needs legal/consent diligence. |
| **Transaction categorisation / merchant enrichment** | Auto-categorise into a taxonomy (Salary, Groceries, …); clean merchant names | partial (rules engine + matcher) | **Enhance** | Ship a **default category taxonomy** and **heuristic auto-categorisation** (later, optional on-device enrichment) to complement the rules engine — good first-run experience without hand-writing every rule. |
| **Savings challenges** | Gamified, time-boxed savings challenges with prompts/notifications | ✗ | **Adopt (Could)** | A motivational layer on savings goals. Distinct, engaging; optional. |
| **Financial wellbeing score** | A single score summarising financial health (spending/saving/debt ratios, buffers) | ✗ | **Adopt (Could)** | An insights indicator for the dashboard; transparent, explainable (not a black box). |
| **Financial Passport** | Download a **PDF snapshot** of finances to securely share (e.g. with a mortgage broker) | partial (PDF report export) | **Adopt (Could)** | A curated net-worth/income/expense **summary export** — a specific, useful report. User-initiated sharing only. |
| **Spending insights / unusual-spend alerts** | Smart alerts on abnormal spend; subscription savings | ✓ (`FR-PLAN-05` alerts) | **Skip (have)** | Covered by the Advisor-FYI alert engine. |
| **Budgets** | Create/track budgets with alerts | ✓ (`FR-BUD-*`, `FR-PLAN-04`) | **Skip (have)** | Covered. |
| **Bills management** | Track recurring bills & due dates | ✓ (`FR-PLAN-01`, `FR-BILL-01`) | **Skip (have)** | Covered. |
| **Savings goals** | Goal setting + progress | ✓ (`FR-GOAL-01` piggy banks) | **Skip (have)** | Covered. |
| **Net worth over time** | Assets + liabilities trend | ✓ (`FR-PLAN-08` dashboard) | **Skip (have)** | Covered. |
| **Account aggregation dashboard** | All accounts in one overview | ✓ (chart of accounts + dashboard) | **Skip (have)** | Covered; CDR would feed it. |

## Recommendation summary

**Adopt (later):**
- **CDR / Open Banking bank sync (Australia)** via an **accredited intermediary** — the AU peer to SimpleFIN/GoCardless. Add to the bank-sync roadmap with explicit consent UX and regulatory diligence. *(P8)*

**Adopt (could):**
- **Savings challenges** (gamified goals) *(P9)*
- **Financial wellbeing score** (explainable dashboard indicator) *(P9)*
- **Financial Passport** (curated shareable PDF summary) *(P9)*

**Enhance:**
- **Default category taxonomy + heuristic auto-categorisation / merchant enrichment** — complements the rules engine and Import Matcher for a good out-of-box categorisation experience. *(P4)*

**Skip (already covered):** insights/alerts, budgets, bills, goals, net worth, aggregation dashboard.

## Positioning

Frollo rounds out the influences into four:

- **GnuCash** → double-entry **rigor**,
- **Microsoft Money** → **planning & guidance**,
- **Firefly III** → **automation & organization**,
- **Frollo** → **connected data (AU Open Banking/CDR), engagement & financial wellness**.

The Frollo-inspired additions respect FinvestLens's local-first, private stance: bank connectivity is **optional and consented**, wellness/engagement features are **on-device computations** over the user's own data.

## References

- [Frollo app](https://frollo.com.au/frollo-app/) · [Frollo Open Banking](https://frollo.com.au/open-banking/) · [Frollo review (Savings.com.au)](https://www.savings.com.au/budgeting-finance-tips/frollo)
- Consumer Data Right — https://www.cdr.gov.au/ · CDR intermediary example — [Basiq](https://basiq.io/)
- Project [PRD](prd.md) · [Architecture](architecture.md) · [Money study](enhancements-msmoney.md) · [Firefly study](enhancements-firefly.md)
