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
| Round-trip corpus CI gate | P3 | not-run | Interop verified manually via `gnucash-cli`; not automated. | P6 |
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
| iOS document flows | New/Open/Import panels are AppKit; iOS uses fileImporter fallbacks, untested. |

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
