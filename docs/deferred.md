# Deferred backlog — open items within P0–P7

Work that was **in scope for the delivered phases (P0–P7)** but is still open:
deferred, partial, or not yet built. It is **ranked** — highest priority /
readiest to pick up first.

Out of scope for this list: the future phases **P8** (extended import / bank
sync) and **P9** (planning & insights), which are planned, not deferred — see
[plan.md](plan.md). Anything already built is in [implemented.md](implemented.md);
intentional non-goals (e.g. bit-for-bit arithmetic parity with GnuCash) are not
tracked anywhere.

Each row cites its PRD `FR-*`/`NFR-*` and the phase it belonged to.

Companions: [Plan](plan.md) · [PRD](prd.md) · [Implemented](implemented.md).

---

## 1 — Release readiness (do first)

Quality automation and validation that a shippable release needs.

| Item | FR / Phase | Notes |
|---|---|---|
| CI: app + Intelligence jobs on a hosted runner | NFR-08 / P0, P3 | `.github/workflows/ci.yml` now builds + tests the seven core packages and gates SPDX headers on every push/PR. The app + Intelligence jobs need **Xcode 26 / macOS 26**, which GitHub's hosted runners don't ship yet (the job is present but `continue-on-error`). Enable it once a macOS-26 runner is available (or a self-hosted one). |
| Large-book perf validation (local + SMB/NFS) | NFR-02 / P1 | **Needs real NAS hardware** — open/scroll/import/save on a 100k-txn book over SMB/NFS. Also settles the one open architecture decision: GRDB **direct-mode vs always-working-copy** on local volumes (Architecture §10). |
| Localization (string catalogs) | NFR-06 / P6 | **Needs translators** — accessibility labels done; the UI-string catalog + translations are not. |

## 2 — User-facing gaps (high value, tractable)

Common workflows partly built; each is a bounded piece of work.

| Item | FR / Phase | Notes |
|---|---|---|
| QIF splits + investment actions | FR-XIO-01 / P4 | Parser handles flat D/T/U/P/M/N/L cash rows; `S/E/$` splits and `!Type:Invst` actions dropped. Needs an extended `StagedTransaction` (splits + security/action/qty/price), matcher routing, and stock-transaction creation — a genuine multi-part feature, not a small gap. |
| OFX investment statements | FR-XIO-02 / P4 | Only `<STMTTRN>` cash rows parsed; `<INVBUY>`/`<INVSELL>` ignored (use the Stock Assistant). Shares the staging/matcher work above. |
| Rule actions tail | FR-RULE-01 / P4 | The engine now has an `account` trigger and set-tags / set-description actions. Remaining: **convert-type**, **link-to-bill**, and **allocate-to-goal**, which need bill-link / savings-goal (`FR-GOAL-01`) infrastructure that isn't built yet. |

*Closed this pass (now in [implemented.md](implemented.md)): CSV export (FR-XIO-06); CSV price import (FR-XIO-03); import GnuCash scheduled transactions + budgets (FR-IMP-03/04); Twelve Data + Stooq quote providers (FR-INV-03b); re-open a finished reconciliation (FR-REC-03); manual attach-a-file (FR-REG-10); Open Read-Only on a live lock (FR-DAT-06); autosave-interval setting (FR-DAT-10); CSV import mapping profiles (FR-XIO-08); free-text search operators (FR-FIND-01); rules `account` trigger + set-tags/set-description (FR-RULE-01, partial); window/state restoration.*

## 3 — Platform enablement ✅ done

The extension targets, entitlements, iCloud container, and App Group are built,
**provisioned, signed, and verified working** on the `com.hellotham.finvestlensapp`
bundle-ID base under team *Hello Tham Pty. Ltd.* (`RPL5R637DS`) — see
[implemented.md](implemented.md) and the [provisioning runbook](provisioning.md):

- **iCloud Documents container** (FR-PLT-02) — `iCloud.com.hellotham.finvestlensapp`,
  CloudDocuments; the book surfaces in iCloud Drive.
- **Widgets** (FR-PLT-03) — `FinvestLensWidgets` signs, embeds, and reads the
  App Group snapshot (`group.com.hellotham.finvestlensapp`).
- **Quick Look preview** (FR-PLT-03) — `FinvestLensQuickLook` signs and previews.
- **App Group** — provisioned; the app↔extension snapshot hand-off works.

> The bundle-ID base moved from `com.hellotham.finvestlens` (held by an
> inaccessible team, so its explicit App ID couldn't be registered) to
> `com.hellotham.finvestlensapp`. The `.finvestlens` **file extension / UTI is
> unchanged** — only the app's identity moved.

## 4 — Feature tails within delivered phases

Lower-priority pieces of features that are otherwise complete.

| Item | FR / Phase | Notes |
|---|---|---|
| Legacy report internals → document scaffold + PDF | FR-RPT-05 / P4 | Transactions, Reconciliation, Forecast, Portfolio, Investment Lots, Price Scatter, Capital Gains keep their interactive views; migrating them onto `ReportDocument` (and giving each PDF export) is follow-up. |
| Check printing | FR-REG-11 / P4 | Not implemented. |
| Savings goals / piggy banks | FR-GOAL-01 / P5 | Not implemented. |
| Managed-fund money-flow realised model | FR-RPT-02 / P5 | Our per-parcel engine subtracts non-fee expense splits booked inside managed-fund transactions where GnuCash's money-in/out model washes them out (~$34k realised across ~6 accounts). Matching would mean adopting GnuCash's money-flow model — arguably not more correct. |
| Business: Australian-Tax invoice layout | FR-BUS-03 / P7 | Printable INVOICE/BILL/VOUCHER PDF built (with an ABN/Tax-ID field on company info); a "Tax Invoice"-titled AU GST layout is todo. |
| Business: time & mileage tracking | FR-PLAN-14 / P7 | Not implemented (no billable-time / mileage model). |
| `rebuildAccountTree` subtree-only rebuild | NFR-02 / P2 | The remaining ~0.04s of a refresh is a full-tree rebuild + search; fast enough to feel instant. Rebuild only the affected subtree if ever needed. |

## 5 — Apple Intelligence import caveats (monitor)

Quality limits of the on-device import layer (PRD §5.18), caught by the review screen.

| Item | FR / Phase | Notes |
|---|---|---|
| Scanned-statement OCR quality | FR-AI-01 / P4 | Vision OCR fallback untested against real bank scans; digital-PDF reflow is solid. |
| Statement sign inference without a balance column | FR-AI-01 / P4 | Signs re-derived from the running balance; statements with unsigned debit/credit columns *and* no balance column may import with wrong signs (the review screen catches it). |
| Smart Import: create a transaction from an unmatched invoice | FR-AI-07 / P7 | An invoice with no matching register transaction reports "import the bank statement first"; direct creation (with a funding-account picker) is not offered. |
| iOS file pickers on-device | FR-AI-01/03/04/07 / P4–P7 | iOS keeps `.fileImporter`; not yet exercised on a device. |

## 6 — Platform & HIG — deferred decisions

| Item | Notes |
|---|---|
| App Sandbox | Disabled by decision: sibling `.lock` files at user-selected locations are denied by the sandbox; related-item declaration + coordinated I/O are in place but macOS still refused. Direct (notarized) distribution doesn't need it. Revisit before any Mac App Store submission. |
| iOS move/rename flow for new books | New books land in the app's Documents directory with safe naming; an in-app move/rename flow is todo. |
| Esc inside a focused text field | AppKit's field editor consumes the raw Escape (completion); ⌘. always cancels, Esc works otherwise. SwiftUI offers no clean override (accepted). |

---

## Accepted divergences (won't-fix)

Not open work — recorded so they aren't re-raised as bugs. Detail in
[implemented.md](implemented.md).

- Currency-commodity export emits `cmdty:fraction`/`name` that GnuCash omits for
  ISO currencies — within FR-EXP-02 tolerance, round-trip byte-verified.
- `isBalanced` treats a sub-minor-unit residual as balanced (ADR-1).
- Average-cost basis keeps full precision to the report edge where GnuCash rounds
  progressively (~2¢ over 40 years).
