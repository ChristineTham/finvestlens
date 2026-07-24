# Deferred backlog — open items within P0–P9

Work that was **in scope for the delivered phases (all of P0–P9)** but is
still open: deferred, partial, or not yet built. It is **ranked** — highest
priority / readiest to pick up first.

Two items were **skipped from the plan by decision** (online bank sync from
P8, TXF export from P9) — §5 below. Anything already built is in
[implemented.md](implemented.md); intentional non-goals (e.g. bit-for-bit
arithmetic parity with GnuCash) are not tracked anywhere.

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
| GnuCash **credit-note** import | FR-BUS-01 / P7 | GnuCash stores a credit note as an invoice with a `credit-note` int64 in `<invoice:slots>`; we don't model credit notes, so such a document imports as an ordinary invoice with the **posting sign inverted** (A/R increased instead of reduced). A real fix is a feature — a credit-note flag on the invoice model, the posting-sign inversion, and UI — not just a parser change. Surfaced by the production review (2026-07-19). |

## 2b — Production-readiness review tail (2026-07-19)

Bounded items surfaced by the full-codebase review (commits `9021a2c`, `be63e62`).
The review fixed every genuine correctness/data-loss bug; these were deferred as
larger-than-a-fix or needing infrastructure that isn't built yet.

| Item | FR / Phase | Notes |
|---|---|---|
| Load-time warning for non-canonical persisted data | NFR-05 / P1 | The SQLite load path defaults silently on unparseable data it never itself writes (`parseDecimal`→0, `parseKvp`→empty frame, `decodeAddress`→empty, GUID parse→random). Kept as resilience (open-what-you-can) — throwing would turn recoverable corruption into "can't open your book". The **warning channel now exists** — the Jul 2026 redesign's status overlay / toast layer (`AppModel.showToast`); what remains is wiring the load path's silent defaults into it. |
| GnuCash-XML round-trip fidelity tail | FR-XIO-01 / P7 | Two minor slots don't round-trip: an invoice entry's `entry:entered` timestamp is re-derived from `entry:date` (needs a separate `entered` field on `InvoiceEntry`), and a KVP `timespec` slot at exactly midnight re-exports as `gdate` (the `KvpValue` model maps both date types to one case). Negligible data impact; each needs a model change. |

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
| Esc inside a focused text field | AppKit's field editor consumes the raw Escape (completion); ⌘. always cancels, Esc works otherwise. SwiftUI offers no clean override (accepted). *The Jul 2026 F19 sweep put `onEscapeCommand` on every sheet — this field-editor caveat is the one remaining Esc limit.* |

## 5 — Skipped from the phase plan (revisit only on demand)

Work removed from a planned phase by decision — neither scheduled nor
won't-fix. It stays recorded here so the reasoning survives.

| Item | FR | Notes |
|---|---|---|
| **TXF export** | FR-PLAN-12 (adjunct) | **Skipped with P9, 24 Jul 2026.** TXF is a US tax-interchange format; the reference book (and the app's AU defaults) has nothing to feed it. The GnuCash `tax-US` code slot still round-trips untouched, so nothing is lost for GnuCash users; build an exporter only if a US user base appears. |
| **Online bank sync** (SimpleFIN / GoCardless (Nordigen); AU **CDR / Open Banking** via an accredited intermediary such as Basiq) | FR-XIO-07 | **Skipped from P8, 24 Jul 2026.** A cloud-mediated, consent-managed connector sits poorly with the app's offline, local-first core (NFR-03/07); the CDR path in particular carries accreditation/intermediary diligence and ongoing API-maintenance burden out of proportion to a document app whose import story (CSV/QIF/OFX files + AI PDF import + the Import Matcher) already covers the data. Revisit only on strong user demand — the design sketch (aggregator → `StagedTransaction` → Import Matcher, credentials user-entered into Keychain) remains valid in [PRD §5.14](prd.md) and the [Frollo study](enhancements-frollo.md). |

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
- **`rebuildAccountTree` subtree-only rebuild / incremental journal rebuild**
  (NFR-02) — the ~0.04s of a refresh spent on a full-tree rebuild is fast
  enough to feel instant; subtree-only and incremental-journal rebuilds are
  micro-optimizations to do only if a profile shows they matter. The Jul 2026
  `Perf` signpost harness now watches exactly these paths, so the trigger is
  a measured number, not a hunch.
- **Investment Review: no benchmark or volatility statistics** (Jul 2026
  report redesign) — fund factsheets carry benchmark-relative performance and
  risk measures (standard deviation, Sharpe); the book holds no benchmark
  series and no return time-series to compute them honestly from, so the
  deck's risk read is **concentration** (largest holding, top-five share) and
  its performance read is return-on-money-in. Revisit only if benchmark data
  ever enters scope.
- **Report computation stays on the main actor** (Jul 2026 redesign) — heavy
  reports are memoised per (parameters, revision) and build behind a
  placeholder after first paint, but the build runs on the main actor: the
  engine `Book` is a non-`Sendable` object graph, and a background read would
  race main-actor edits. Going further needs a book **read-gate** (writers
  wait on in-flight readers) — deliberately deferred until the memoised
  first-build is shown too slow in practice (Architecture §10).
- **Local-time date bucketing** (production review, 2026-07-19) — reports and the
  register bucket dates with `Calendar.current` throughout, an internally
  consistent local-time convention. GnuCash files store dates in UTC, so an
  imported day-only date can appear on the adjacent local day at a period edge;
  aligning would be a project-wide canonical-timezone decision, not a local fix,
  and changing only reports would be the regression.
- **Quotes record the caller-specified currency** (production review) — a fetched
  `Price` is stamped with the currency the caller asked for, not the provider's
  reported `currencyCode` (which rides in `source` for provenance). Multi-currency
  FX valuation is a higher layer by design.
- **GnuCash-XML element text is whitespace-trimmed on import** (production review) —
  leading/trailing whitespace in memos/descriptions/notes/names is dropped so XML
  indentation can't leak into values; byte-for-byte text fidelity is sacrificed by
  choice.
