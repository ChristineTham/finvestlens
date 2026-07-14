# Deferred backlog (P0–P5)

Tracks items that were in scope for a completed phase but deferred, partial, or
never run. Intentional non-goals (e.g. bit-for-bit arithmetic parity with
GnuCash) are **not** listed.

**Status of the functional backlog:** all functional deficits below have been
**implemented** (see the "Resolved" section). The only items still outstanding
are **CI** and **GnuCash round-trip fidelity / perf validation**, deliberately
left for later.

## Still outstanding (intentionally deferred)

| Item | Origin | Status | Notes | Target |
|---|---|---|---|---|
| CI pipeline + file-header/coverage gate | P0 | absent | Tests run locally; no `.github`. | P6 |
| 100k-txn perf validation (local + SMB/NFS) | P1 (NFR-02, OD-1/2/3) | not-run | Go/no-go for GRDB direct-mode vs working-copy. | P6 |
| Round-trip corpus CI gate | P3 | partial | Interop verified manually via `gnucash-cli`. **14 Jul 2026:** deep round-trip on a real 8.5 MB book (560 accounts, 46,578 txns, 102,706 prices) now **CLEAN** — full graph + balances identical, double export byte-identical. Found & fixed: template-transactions ROOT hijacked the book (orphaning every real account), price/amount precision loss (exporter rounded to currency SCU; now exact rationals with continued-fraction recovery for FX cross-rates), book GUID not re-imported. Re-runnable harness: `FL_ROUNDTRIP_FILE=… swift test --filter LiveFileRoundTripTests`; CI automation still pending. | P6 |
| ~~Richer slot (KVP) round-trip~~ | P3 | **done** | **14 Jul 2026:** all slots on book/account/transaction/split are preserved verbatim through import/export (nested frames, lists, gdate/timespec, guid, numeric, integer); `notes` is lifted into `Account.notes`/`Transaction.notes`. Verified on the real 8.5 MB book (18,646 notes, 3,944 online_id, colours, reconcile-info) — round-trip clean incl. KVP equality. **Commodity fidelity closed too (14 Jul 2026):** `Commodity` gained `exchangeCode`/`getQuotes`/`quoteSource`/`quoteTimezone`/`kvp` (identity stays namespace+mnemonic; backward-compatible Codable + sqlite v2 migration), so `cmdty:xcode`, quote config, and `cmdty:slots` (`user_symbol`) round-trip. The live harness now also compares the export against the **original** file's inventory (slot-key multiset, entity + cmdty element counts) — clean on the real book. | done |
| Budgets/scheduled/business in native GnuCash slots | P3 | partial | Persist as KVP-JSON, not GnuCash XML slots. | P7 |
| iCloud Documents container | P6 (FR-PLT-02) | needs-capability | Sync machinery done + storage-agnostic; enabling the container needs a dev team/provisioning. | P6+ |
| Widgets | P6 (FR-PLT-03) | needs-target | WidgetKit extension target; IntentSupport summaries ready to feed it. | P6+ |
| Quick Look preview | P6 (FR-PLT-03) | needs-target | Quick Look extension target. | P6+ |
| Push notifications for alerts | P6 (FR-PLAN-05) | needs-entitlement | Alerts engine + dashboard done; UNUserNotificationCenter delivery pending. | P6+ |
| Localization (string catalogs) | P6 (NFR-06) | absent | Accessibility labels done; UI strings not yet localized. | P6+ |

## Resolved (functional deficits — implemented)

| Item | FR | Origin | Commit theme |
|---|---|---|---|
| Tags (model + editor + `tag:` search) | FR-TAG-01 | P2 | tags/operator search |
| Operator search language | FR-FIND-01 | P4 | tags/operator search |
| Account codes + renumber | FR-COA | P2 | account renumber |
| Register styles (journal / general ledger) | FR-REG-01 | P2 | register styles |
| Transaction Report | FR-RPT-04 | P4 | transaction report |
| Report PDF export | FR-RPT | P4 | report PDF export |
| Saved searches | FR-FIND-01 | P4 | saved searches |
| Merchant cleanup + heuristic categorisation | FR-RULE-03 | P4 | merchant heuristics |
| Default taxonomy / starter chart | FR-COA-03 | P4 | starter chart |
| Onboarding assistant | FR-PLAN-09 | P4 | onboarding |
| Bill reminders + Financial Calendar + matching | FR-PLAN-01, FR-BILL-01 | P4 | bill reminders |
| Budget rollover / envelope | FR-BUD-02 | P4 | advanced budgets |
| Auto-budget replenish / zero-based | FR-BUD-03, FR-PLAN-04 | P4 | advanced budgets |
| Return-of-capital action | FR-INV-04 | P5 | return-of-capital |
| Investment Lots + Price Scatter + rate of return | FR-RPT-02 | P5 | investment reports |
| Stock splits | FR-INV-04 | P5 | stock splits |
| Security Editor | FR-INV-07 | P5 | security editor |
| Watch lists | FR-PLAN-07 | P5 | watch lists |
| Trading accounts (multi-currency FX balancing) | FR-CUR, FR-REG-07 | P5 | trading accounts |
| Scheduled quote auto-refresh | FR-INV-03 | P5 | quote auto-refresh |
| Rules apply-to-historical + preview | FR-RULE-02 | P5 | (done earlier in P5) |
| What-if scenarios on cash flow | FR-PLAN-03 | P5 | (done earlier in P5) |
| UTI / document-type registration | FR-PLT-04 | P1 | document type + onOpenURL |

## Usability review (July 2026)

Resolved in the usability pass: File/Book menu bar (New/Open/Open Recent/
Import GnuCash/Export/Close/Revert + every tool panel with shortcuts), lean
toolbar with a Tools menu, GnuCash import UI (File menu + welcome screen),
price-target editor, account re-parenting, stale-lock Break-Lock recovery,
iCloud conflict-version resolution in the external-change banner, welcome
recents.

Still deferred:

| Item | Notes |
| --- | --- |
| App Sandbox | Disabled by decision (13 Jul 2026): sibling `.lock` files at user-selected locations are denied by the sandbox; related-item declaration + coordinated I/O are in place but macOS still refused. Direct (notarized) distribution doesn't need the sandbox. Revisit before any Mac App Store submission. |
| iOS document flows | New/Open panels are AppKit on macOS; iOS uses fileImporter. First run in the simulator 14 Jul 2026: welcome → Open… → Files picker → book opens and renders. **New Book fixed (14 Jul 2026):** iOS books are created in the app's Documents directory (visible in Files under "On My iPhone ▸ finvestlens") with non-colliding Untitled/Untitled 2 naming — no longer the purgeable temporary directory. Still open: a move/rename flow for new books. **GnuCash/bank-file import and export are intentionally macOS/iPadOS-only** (`FR-PLT-06`, PRD §5.15) — iPhone is open/create/edit only, so their absence on iOS is by design, not a gap. |
| ~~iOS: open a book from iCloud Drive / Files~~ | **Done (14 Jul 2026):** coordinated reads materialise dataless files; security-scoped access held for the session with bookmark-backed recents; lockless fallback (Architecture §6.1/§6.3) where the sibling `.lock` can't be created. Verified: Box Drive + iCloud Drive (incl. evicted file) on macOS, Files-picker open in the iOS simulator. Dropbox uses the same File Provider mechanism as Box (not separately tested — not installed). | 

## HIG review (13 Jul 2026)

Fixed: undo/redo (snapshot-based, Edit menu integrated), save-on-quit via
NSApplicationDelegate (⌘Q never loses data, releases the lock), Reports in
its own window, window titled with document proxy icon, Esc/⌘. cancels
sheets (+ Return confirms reconcile), toolbar help tags, Title Case buttons.

Known nuances / still deferred:

| Item | Notes |
| --- | --- |
| Esc inside a focused text field | AppKit's field editor consumes the raw Escape (completion); ⌘. always cancels, Esc works otherwise. SwiftUI offers no clean override. |
| Undo action names | Generic "Undo Change" — per-operation names ("Undo Delete Transaction") need call-site annotations. |
| Window/state restoration | App launches to the splash; does not reopen the last book automatically. |
| Help menu | No help book / anchors. |

## 1.0 PRD audit (13 Jul 2026)

Full code review against the PRD before tagging 1.0. Fixed during the audit:
hardcoded AUD in the transaction editor (now derives the transaction currency
from the splits' accounts), silent save failures on book-switch/quit/conflict
resolution (now surfaced, quit cancels on failure), transaction-editor errors
no longer silently dismissed, **lock heartbeat timer** (idle books no longer
go stale-breakable), **autosave** (5-minute interval), stale importer/OFX
comments.

Known 1.0 scope limits (post-1.0 backlog, in priority order):

| Item | FR | Notes | Target |
|---|---|---|---|
| QIF splits + investment actions | FR-XIO-01 | Parser handles flat D/T/U/P/M/N/L cash rows only; `S/E/$` splits and `!Type:Invst` actions dropped. | P8 |
| OFX investment statements | FR-XIO-02 | Only `<STMTTRN>` cash rows parsed; `<INVBUY>`/`<INVSELL>` ignored (use the Stock Assistant). | P8 |
| CSV price import | FR-XIO-03 | CSV imports transactions only. | P8 |
| CSV export | FR-XIO-06 | No CSV export (GnuCash XML export covers interchange). | P8 |
| CSV mapping profiles | FR-XIO-08 | Column mapping is per-import; no saved profiles. | P8 |
| GnuCash `sx:`/budget/business import | FR-IMP-03/05 | Counted as import warnings; FinvestLens keeps its own in KVP slots. | P7/P8 |
| Savings goals / piggy banks | FR-GOAL-01 | Not implemented. | P9 |
| Twelve Data quote provider | FR-INV-03b | Yahoo/EODHD/Alpha Vantage/Finnhub shipped; Twelve Data/Stooq not. | P8 |
| Scheduled-split formulas | FR-SCH-02 | Fixed amounts only. | P8 |
| Re-open a finished reconciliation | FR-REC-03 | Begin/toggle/finish/cancel only. | P8 |
| Loan amortization assistant | FR-SCH-04 | Not implemented. | P9 |
| Transaction attachments | FR-REG-10 | Not implemented. | P8 |
| Check printing | FR-REG-11 | Not implemented. | P9 |
| Open Read-Only on live lock | §6.1 | Open fails with holder info + Break-Lock; no read-only mode. | P7 |
| Autosave interval setting | §3 | Fixed 5 min; not user-configurable/disableable yet. | P7 |
| Business (P7), bank sync/MT940/CAMT (P8), planners (P9) | FR-BUS, FR-XIO-04/07, FR-PLAN-10.. | Post-1.0 phases per plan.md. | P7–P9 |

## Apple Intelligence (13 Jul 2026)

Post-1.0 addition of the `Intelligence` package (FR-AI-01…06, Architecture
§11). Fixed along the way (pre-existing 1.0 bugs uncovered by GUI testing):
**File-menu Save/Revert/Import/Export/Close Book were silently missing**
(`CommandGroup(after: .saveItem)` has no anchor in a plain WindowGroup —
re-anchored to `.newItem`), and **bank-file import never presented its picker
on macOS** (SwiftUI `.fileImporter` unreliable here; replaced with NSOpenPanel,
deferred out of the view-update transaction).

Known limits:

| Item | FR | Notes | Target |
|---|---|---|---|
| Guardrail refusals | FR-AI-05 | On-device safety layer deterministically refuses some borderline inputs; budget advisor retries simplified phrasing then falls back to average-based plan. Other features surface a friendly message. | monitor |
| Scanned-statement OCR quality | FR-AI-01 | Vision OCR fallback is untested against real bank scans; digital-PDF reflow is solid. | P8 |
| Statement sign inference without balance column | FR-AI-01 | Signs are re-derived from the running balance; statements with unsigned debit/credit columns *and* no balance column may import with wrong signs (review screen catches). | P8 |
| ~~Invoice → attachment link~~ | FR-AI-03 | **Done (FR-AI-08):** Smart Import copies applied invoice/dividend PDFs into the document folder and links them via the GnuCash `assoc_uri` slot ("Open Linked Document" in the register). Manual attach from the transaction editor is still not offered. | done / P8 |
| iOS file pickers | FR-AI-01/03/04/07 | iOS keeps `.fileImporter`; not yet exercised on-device. | P8 |
| Smart Import: create transaction from unmatched invoice | FR-AI-07 | An invoice with no matching register transaction reports "import the bank statement first"; direct creation (with funding-account picker) not offered yet. | P8 |
| ~~statementDate in GnuCash XML~~ | FR-AI-07 | **Done (14 Jul 2026):** with generic KVP round-trip, the `finvestlens/statement-date` slot now rides through XML export/import (timespec, full fidelity), so dual-date duplicate detection survives a GnuCash round-trip. GnuCash itself ignores but preserves the slot. | done |
| Live-model tests under load | — | `LiveModelTests` can time out when the model daemon is busy; they self-skip without Apple Intelligence. Not in CI. | monitor |
| Journal / General Ledger scroll position | FR-REG-01/08 | The basic register opens on the newest posting and supports ⌘↑/⌘↓ jumps; the journal styles still open on the oldest. `ScrollViewProxy.scrollTo` forces a `List` to lay out every section ahead of the target, and the general ledger spans the whole book — on the 46k-transaction test file that pinned a core and passed 1 GB resident without settling. Needs `journalEntries` memoised (it currently rebuilds all entries on every body pass) and a paged window rather than 46k live sections. | P8 |
| Opening a book blocks the main thread | FR-DOC-01 | `AppModel.open(at:)` is fully synchronous: measured **45.2s** for the 46k-transaction / 102k-price Ashley Bears book. The window cannot repaint for the duration, so the click looks ignored and there is no progress indication. Re-opening the already-open book is now a no-op (so an impatient second click no longer closes and re-reads it), but the underlying fix is to load off the main actor and show progress — `Book` is a reference graph and not `Sendable`, so this needs the load to hand back a value type or an isolated actor. | P8 |
