# GnuCash menu parity audit

A full audit of FinvestLens's GUI against every GnuCash menu, to confirm that
all implemented functionality is reachable from the interface and to record
where FinvestLens meets, exceeds, or falls short of GnuCash.

**Method.** GnuCash 5.x was open on the same book (`Ashley Bears`) during the
audit. Its **Actions**, **Tools** and **View** menus — where the functional
verbs live — were read directly from the running app; the **File / Edit /
Reports / Business** menus were cross-referenced against FinvestLens's command
tree in [`finvestlens/finvestlensApp.swift`](../finvestlens/finvestlensApp.swift)
rather than clicked through one item at a time. FinvestLens surfaces every tool
panel from the menu bar with a shortcut, and mirrors the register verbs through
a shared `TransactionActions` view so the menu bar cannot drift from the context
menu.

Legend: **=** parity · **+** exceeds GnuCash · **−** gap (see notes).

---

## File

| GnuCash | FinvestLens | |
|---|---|---|
| New / Open / Open Recent | New Book…, Open…, Open Recent | = |
| Save / Revert | Save (⌘S), Revert to Saved | = |
| Import ▸ (QIF/OFX/CSV/…) | Import Bank File… (CSV/QIF/OFX-QFX), Import GnuCash…, Smart Import PDFs… | **+** (PDF/AI import has no GnuCash equivalent) |
| Export ▸ (accounts/transactions) | Export GnuCash… (⇧⌘E) | = |
| Print / Print Preview | Reports → Print / PDF export | = (register itself isn't printed; reports are) |
| Properties (book currency, options) | Settings, per-book options via panels | = |
| Close / Quit | Close Book (⇧⌘W), Quit | = |

## Edit

| GnuCash | FinvestLens | |
|---|---|---|
| Cut / Copy / Paste | Standard pasteboard group | = |
| Find… | Find… (⌘F), Find Account… (⌘I), Clear Find | **+** (saved searches, tag search) |
| Edit / Delete Account | Book ▸ New Account…; account context menu edit/delete | = |
| Preferences | Settings (Appearance, document folder, …) | = |
| Tax Report Options | — | − (no tax-report scheduling; capital-gains report exists) |

## View

| GnuCash | FinvestLens | |
|---|---|---|
| Toolbar / Status Bar / Tab Bar | Native toolbar; single-window navigation | = |
| **Summary Bar** (Present/Future/Cleared/Reconciled/Projected Min.) | **register summary bar** | = — *see [deferred.md] history; added by this audit* |
| Basic Ledger / Auto-Split / Transaction Journal | Register styles: Basic / Journal / General Ledger | = |
| Double Line | Double-line toggle (`registerDoubleLine`) | = |
| Sort By… | `sortMenu` in the register toolbar | = |
| Filter By… | Filter button → `RegisterFilterSheet` (date / reconcile state) | = |
| Open Subaccounts | Subaccounts toggle (`registerIncludesSubaccounts`) | = |
| Refresh | Automatic (Observation) | = |

## Transaction (register verbs)

| GnuCash | FinvestLens | |
|---|---|---|
| Enter / Cancel / Duplicate | Transaction menu + editor (shared `TransactionActions`) | = |
| Delete / Void | Delete, Void | = |
| Add Reversing Transaction | Add Reversing Transaction | = |
| Jump to the other account | Go to Other Account | = |
| Associate File / Location | Linked documents (`assoc_uri`); Open Linked Document | = |
| Cut/Copy/Paste Transaction | Duplicate covers the common case | ≈ |

## Actions

| GnuCash | FinvestLens | |
|---|---|---|
| Transfer… (⌘T) | New Transaction…, Currency Transfer… | = |
| Reconcile… | Reconcile Account… (⇧⌘R) | = |
| Auto-clear… | Reconcile session clears matching splits | ≈ |
| Stock Split… | Stock Transaction… (splits, return-of-capital) | = |
| View Lots… | Capital-gains / cost-basis report (FIFO/LIFO/avg) | ≈ (report, not a lot editor) |
| Blank Transaction (⌘B) | New Transaction… (⌘T) | = |
| Go to Date | Register ▸ Go to Date… → `GoToDateSheet` / `goToDate`; plus ⌘↑/⌘↓ to ends | = |
| Split Transaction | Multi-split transaction editor | = |
| Edit Exchange Rate | Currency Transfer sets the rate | ≈ |
| Scheduled Transactions ▸ | Scheduled Transactions… | = |
| Budget ▸ | Budget… (⌘B) — rollover/envelope/zero-based | **+** |
| Check & Repair ▸ | Check & Repair… | **+** (proposes, previews, one undo) |

## Business

| GnuCash | FinvestLens | |
|---|---|---|
| Customers / Vendors / Employees | Customers, Vendors & Invoices… (⇧⌘B) | = (employees folded in) |
| Invoices / Bills / Vouchers | Invoice editor, aging | = |
| Receivable/Payable Aging | Receivable Aging…, Payable Aging… | = |

## Reports

| GnuCash | FinvestLens | |
|---|---|---|
| Assets & Liabilities (Balance Sheet, Net Worth) | Balance Sheet, Net Worth, Average Balance | = |
| Income & Expense (P&L, Income Statement) | Income Statement, comparative | = |
| Investment (Portfolio, Advanced Portfolio) | Portfolio, capital gains, allocation | = |
| Business (Aging, Customer/Vendor summary) | Aging, customer summary | = |
| Transaction Report | Transaction Report | = |
| Print / Export report | Print / PDF export | = |

## Tools

| GnuCash | FinvestLens | |
|---|---|---|
| Price Database | Prices & Quotes… | = |
| Security Editor | Securities / watch list (via Prices & Quotes and Securities) | = |
| General Journal | Register style: General Ledger | = |
| Transaction Linked Documents | Per-transaction linked docs | ≈ (no book-wide linked-doc list) |
| Import Map Editor | Rules… (categorisation rules) | ≈ |
| Close Book… (period-end closing) | — | − (no accounting-period close) |
| Loan Repayment Calculator | — | − (no financial calculator) |
| Online Banking Setup | — | n/a (bank-file/PDF import instead, by design) |

## Windows / Help

| GnuCash | FinvestLens | |
|---|---|---|
| Windows (tab management) | Single-window; Reports opens its own window | = |
| Tutorial / Help / About | About; onboarding starter chart | ≈ (no bundled manual) |

---

## Summary of gaps

**Surfaced by this audit** (implemented capability that had no GUI entry point):

- **Register summary bar** — the engine already computes cleared/reconciled
  balances via `BalanceFilter`; the register now shows Present / Cleared /
  Reconciled / (for a leaf) shares, matching GnuCash's status strip.

**Genuine functional gaps** (not yet implemented; candidates, not commitments):

- **Close Book** — period-end closing entries (distinct from closing the file).
- **Loan Repayment Calculator** — amortisation schedule.
- **Book-wide Linked Documents list** (Tools ▸ Transaction Linked Documents);
  per-transaction links exist, the roll-up view does not.
- **Tax Report Options** — TXF-style tax scheduling of accounts.

**Where FinvestLens exceeds GnuCash:** AI/PDF Smart Import, saved searches and
tag search, envelope/zero-based budgets, a previewing Check & Repair with single
-action undo, and the home dashboard with alerts.
