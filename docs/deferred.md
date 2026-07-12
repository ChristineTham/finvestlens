# Deferred backlog (P0–P5)

Items that were in scope for a completed phase but deferred, partially built, or
skipped. Each row notes the originating phase, the FR reference where one exists,
a short status, and a suggested phase to pick it up. Intentional non-goals (e.g.
bit-for-bit arithmetic parity with GnuCash) are **not** listed here.

Status legend: **absent** (not built) · **partial** (a subset shipped) ·
**not-run** (task never executed).

## Cross-cutting (call these out first)

| Item | Origin | Status | Notes | Target |
|---|---|---|---|---|
| CI pipeline + file-header/coverage gate | P0 | absent | No `.github`; tests run locally only. The ≥90%-coverage exit criterion is unmeasured. | P6 |
| 100k-txn perf validation (local + real SMB/NFS) | P1 (NFR-02, OD-1/2/3) | not-run | Documented go/no-go for GRDB direct-mode vs always-working-copy. Still unresolved. | P6 |
| Report print / PDF export | P4 | absent | No printing anywhere in the app. | P6 |
| Native round-trip of budgets/scheduled/business objects | P3 | partial | These persist only as KVP-JSON, not GnuCash XML slots. Prices *do* round-trip. | P7 (with business objects) |

## P0 — Foundation

| Item | FR | Status | Notes | Target |
|---|---|---|---|---|
| CI + automated GPLv3 header check | — | absent | See cross-cutting. | P6 |

## P1 — Native document & import

| Item | FR | Status | Notes | Target |
|---|---|---|---|---|
| 100k-txn perf on local + SMB/NFS | NFR-02, OD-1/2/3 | not-run | See cross-cutting; gates OD-1/2/3. | P6 |
| UTI / document-type registration for `.finvestlens` | FR-PLT-04 | absent | App opens via in-app file picker; no Finder double-click / OS registration. | P6 |

## P2 — Core UX

| Item | FR | Status | Notes | Target |
|---|---|---|---|---|
| Register styles: auto-split / journal / general-ledger | FR-REG-01 | partial | Only the basic register exists. | P6 |
| Tags (model + minimal UI) | FR-TAG-01 | absent | Not implemented. | P6 |
| Account codes + renumber | FR-COA | partial | Reparent/rename present; code renumbering absent. | P6 |

## P3 — Export & round-trip

| Item | FR | Status | Notes | Target |
|---|---|---|---|---|
| Budgets/scheduled/business in native GnuCash slots | FR-EXP | partial | KVP-JSON only; stale code comment says "not yet written". | P7 |
| Round-trip corpus CI gate | FR-EXP-02, NFR-08 | partial | Interop verified manually via `gnucash-cli`; not automated. | P6 |

## P4 — Everyday finance

| Item | FR | Status | Notes | Target |
|---|---|---|---|---|
| Transaction Report | FR-RPT-04 | absent | — | P6 |
| Report PDF / print | FR-RPT | absent | See cross-cutting. | P6 |
| Budget rollover / envelope | FR-BUD-02 | absent | Only per-account budgets + budget-vs-actual shipped. | P9 |
| Auto-budget replenish / zero-based | FR-BUD-03, FR-PLAN-04 | absent | — | P9 |
| Default category taxonomy + heuristic auto-categorisation / merchant cleanup | FR-RULE-03 | absent | Frollo-inspired; basic rules engine shipped. | P8 (with bank sync) |
| Saved searches | FR-FIND-01 | absent | Operator search grammar is present. | P6 |
| Bill reminders + Financial Calendar + bill matching | FR-PLAN-01, FR-BILL-01 | absent | — | P6 |
| Onboarding / setup assistant (starter chart of accounts) | FR-PLAN-09, FR-COA-03 | absent | Welcome screen is New/Open only. | P6 |

## P5 — Investments (complete; explicitly deferred)

| Item | FR | Status | Notes | Target |
|---|---|---|---|---|
| Security Editor (edit commodity in place) | FR-INV-01/07 | absent | Risky with existing postings; creation already sets metadata. | P6 |
| Trading accounts (exact multi-currency FX-gain balancing) | FR-CUR, FR-REG-07 | absent | Balance-sheet residual is the unrealised FX gain; `isBalanced` is informational. | P6 |
| Scheduled quote auto-refresh | FR-INV-03 | absent | Needs background-task infra. | P6 |
| Watch lists (securities not held) | FR-PLAN-07 | absent | — | P6/P9 |
| Return-of-capital action in the Stock Assistant | FR-INV-04 | absent | Minor; reduces cost basis without proceeds. | P6 |
