# Enhancement Study — Firefly III

| | |
|---|---|
| **Document status** | Draft v0.1 |
| **Last updated** | 2026-07-12 |
| **Purpose** | Evaluate Firefly III features and decide which should enhance FinvestLens |
| **Companions** | [PRD](prd.md) · [Architecture](architecture.md) · [Money study](enhancements-msmoney.md) |
| **Upstream** | [docs.firefly-iii.org](https://docs.firefly-iii.org) · [github.com/firefly-iii/firefly-iii](https://github.com/firefly-iii/firefly-iii) |

## Why look at Firefly III

Firefly III is a modern, self-hosted personal-finance manager with a loyal following. Its accounting model overlaps GnuCash (asset/expense/revenue/liability accounts; withdrawals/deposits/transfers), so the *engine* holds few surprises. Its value for us is a different axis again: where GnuCash brings **rigor** and Microsoft Money brings **planning**, Firefly III brings **automation and organization** — a genuinely powerful rule engine, flexible tagging, savings goals, an operator search language, and modern bank-sync APIs. These are the features worth mining.

## Feature-by-feature evaluation

Legend — **Adopt** (build), **Enhance** (upgrade an existing planned feature), **Later**, **Skip**. "Have?" = covered by current PRD.

| Firefly feature | What it does | Have? | Verdict | Notes |
|---|---|---|---|---|
| **Rule engine** | Rule **groups** (ordered) of rules; each rule has **triggers** (strict = AND / non-strict = ANY) over many fields and **actions** (set category/budget/tags/description/notes, convert type, link to bill, add to piggy bank); **stop-processing** flag; runs on create/update, on import, manually, and can be **applied to historical** transactions with a **preview** | partial (`FR-PLAN-06` payee rules) | **Enhance → full rules engine** | Firefly's signature feature; far beyond Money's payee rules. Supersedes `FR-PLAN-06`. Huge automation value, especially post-import. |
| **Tags** | Cross-cutting labels on transactions (optionally with dates/locations), independent of the category/account hierarchy | ✗ | **Adopt** | GnuCash has no tags. A lightweight second classification axis; pairs with rules and search. |
| **Piggy banks (savings goals)** | Divide an asset account's balance into named goals; add/remove money; **link transfers** so they auto-allocate; **group** piggy banks; link a piggy bank to a bill | ✗ (Money's Lifetime Planner is different — long-range projection) | **Adopt** | Beloved, lightweight goal-tracking. Complements, doesn't duplicate, the Money planner. |
| **Operator search language** | Query syntax: `type:`, `from:`/`to:`, date operators (`on`/`before`/`after` with `d/w/m/y` offsets), `amount`, `category`, `tag`, notes/attachment operators, negation with `-` (AND-joined) | partial (`FR-REG-06` find/filter) | **Enhance** | Upgrade our search into a real operator query language; powers saved searches and rule triggers (shared grammar). |
| **Bill matching** | Bills/subscriptions with an **expected amount/range and interval**; transactions auto-match to bills; flags **paid / not-yet-paid / overdue** | partial (`FR-PLAN-01` bill reminders) | **Enhance** | Add matching + expected-amount ranges to our bill reminders. |
| **Auto-budgets** | Budgets that **auto-replenish** each period (fixed or rollover); zero-based budgeting workflow | partial (`FR-BUD-*`, `FR-PLAN-04`) | **Enhance** | Fold auto-replenish into the budget-rollover work. |
| **Recurring transactions** | Scheduled auto-creation of transactions | ✓ (`FR-SCH-*`) | **Skip (have)** | Covered by scheduled transactions. |
| **Multi-currency / foreign amounts / auto exchange rates** | Per-transaction foreign amounts; automatic rate lookup | ✓ (`FR-CUR-*`, quote providers) | **Skip (have)** | Already planned. |
| **Attachments** | Attach files to transactions | ✓ (`FR-REG-10`) | **Skip (have)** | Already planned (document association). |
| **Reconciliation** | Reconcile accounts to statements | ✓ (`FR-REC-*`) | **Skip (have)** | Already planned. |
| **Data importer: bank sync** | Separate importer supporting CSV, CAMT.053, and **GoCardless (Nordigen)**, **Salt Edge (Spectre)**, **SimpleFIN** open-banking providers | partial (CSV/QIF/OFX; online banking deferred) | **Later — modernize online banking** | **SimpleFIN/GoCardless are the modern, developer-friendly alternative to OFX DirectConnect/AqBanking.** Reframe our deferred online-banking path around these. Add **CAMT.053** to the import roadmap. |
| **REST API (JSON) + OAuth** | Full programmatic API | ✗ (native document app, not a server) | **Skip** | A server feature that doesn't fit a native document app. The automation use-case is served by **App Intents / Shortcuts** (`FR-PLT-03`), not an HTTP API. |
| **Webhooks** | Fire HTTP callbacks on transaction create/update/delete | ✗ | **Skip** | Server-oriented; out of scope for a native app. Revisit only if a companion sync service ever exists. |
| **Object groups** | Group piggy banks / bills for organization | ✗ | **Fold-in** | Minor; comes along with piggy banks/bills as an optional grouping field. |
| **Audit logging** | History of changes | partial | **Later / Could** | Useful for trust; low priority. |

## Recommendation summary

**Enhance existing plans:**
- **Rules engine** (triggers/actions/groups/stop-processing/apply-to-historical/preview) — upgrade and **supersede** `FR-PLAN-06`. *(P4/P5)*
- **Operator search language** — upgrade `FR-REG-06`; shared grammar with rule triggers and saved searches. *(P2/P4)*
- **Bill matching + expected-amount ranges** — extend `FR-PLAN-01`. *(P4)*
- **Auto-budgets / zero-based** — extend budget-rollover work. *(P4)*

**Adopt (new):**
- **Tags** — cross-cutting transaction labels. *(P2/P4)*
- **Piggy banks / savings goals** — per-account goal allocation, linkable to transfers/bills. *(P5)*

**Later:**
- **Modern bank sync** via **SimpleFIN / GoCardless** (and **CAMT.053** file import) — the preferred path for online banking, replacing the old OFX-DirectConnect/AqBanking framing. *(P8)*
- **Audit logging.** *(P9)*

**Skip:** REST API and webhooks (server features; automation is covered natively by App Intents/Shortcuts). Recurring transactions, multi-currency, attachments, reconciliation (already have).

## Positioning

Layered onto the [Money study](enhancements-msmoney.md), Firefly III completes a three-way synthesis:

- **GnuCash** → double-entry **rigor** (the engine),
- **Microsoft Money** → **planning & guidance** (forecasting, lifetime/debt planners, alerts),
- **Firefly III** → **automation & organization** (rules, tags, goals, powerful search, modern bank sync).

All three sit on top of the same accounting core as read-models, guided workflows, or automation — none weakens double-entry integrity.

## References

- [Introduction & features](https://docs.firefly-iii.org/explanation/firefly-iii/about/introduction/) · [Rules](https://docs.firefly-iii.org/how-to/firefly-iii/features/rules/) · [Rule actions](https://docs.firefly-iii.org/references/firefly-iii/rule-actions/)
- [Piggy banks](https://docs.firefly-iii.org/explanation/financial-concepts/piggy-banks/) · [Zero-based budgeting](https://docs.firefly-iii.org/explanation/firefly-iii/background/zero-based-budgeting/) · [Search options](https://docs.firefly-iii.org/references/firefly-iii/search/)
- Bank sync — [GoCardless](https://gocardless.com/bank-account-data/) · [SimpleFIN](https://www.simplefin.org/) · CAMT.053 (ISO 20022)
- Project [PRD](prd.md) · [Architecture](architecture.md) · [Money study](enhancements-msmoney.md)
