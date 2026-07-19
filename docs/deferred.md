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
| Rule actions tail | FR-RULE-01 / P4 | The engine now has an `account` trigger and set-tags / set-description / **allocate-to-goal** (`FR-GOAL-01`) actions. Remaining: **convert-type** (fuzzy in a double-entry model) and **link-to-bill** (needs bill-link infrastructure not yet built). |

## 3 — Apple Intelligence import caveats (monitor)

Quality limits of the on-device import layer (PRD §5.18), caught by the review screen.

| Item | FR / Phase | Notes |
|---|---|---|
| Scanned-statement OCR quality | FR-AI-01 / P4 | Vision OCR fallback untested against real bank scans; digital-PDF reflow is solid. |
| Statement sign inference without a balance column | FR-AI-01 / P4 | Signs re-derived from the running balance; statements with unsigned debit/credit columns *and* no balance column may import with wrong signs (the review screen catches it). |
| iOS file pickers on-device | FR-AI-01/03/04/07 / P4–P7 | iOS keeps `.fileImporter`; not yet exercised on a device. |

## 4 — Platform & HIG — deferred decisions

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
- **Managed-fund money-flow realised model** (FR-RPT-02) — our per-parcel engine
  subtracts non-fee expense splits booked inside managed-fund transactions where
  GnuCash's money-in/out model washes them out (~$34k realised across ~6
  accounts). Matching would mean adopting GnuCash's money-flow model, which is
  arguably *not* more correct — kept per-parcel by decision.
- **`rebuildAccountTree` subtree-only rebuild** (NFR-02) — the ~0.04s of a
  refresh spent on a full-tree rebuild is fast enough to feel instant; a
  subtree-only rebuild is a micro-optimization to do only if a future profile
  ever shows it matters.
