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
| Tax Report Options | Edit ▸ Tax Report Options… — flag accounts, tax code, schedule | = (flags round-trip via `tax-related`/`tax-US` slots) |

## View

| GnuCash | FinvestLens | |
|---|---|---|
| Toolbar / Status Bar / Tab Bar | Native toolbar; single-window navigation | = |
| **Summary Bar** (Present/Future/Cleared/Reconciled/Projected Min.) | **register summary bar** | = — *added by this audit; see [implemented.md](implemented.md)* |
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
| Transaction Linked Documents | Book ▸ Linked Documents… (book-wide roll-up) | = |
| Import Map Editor | Rules… (categorisation rules) | ≈ |
| Close Book… (period-end closing) | Book ▸ Period-End Close… | = |
| Loan Repayment Calculator | Book ▸ Loan Calculator… | = |
| Online Banking Setup | — | n/a (bank-file/PDF import instead, by design) |

## Windows / Help

| GnuCash | FinvestLens | |
|---|---|---|
| Windows (tab management) | Single-window; Reports opens its own window | = |
| Tutorial / Help / About | About; onboarding starter chart | ≈ (no bundled manual) |

---

## Summary of gaps

**Closed by this audit** (every gap it found has since been built):

- **Register summary bar** — Present / Cleared / Reconciled from the engine's
  existing `BalanceFilter`, matching GnuCash's status strip to the cent.
- **Book-wide Linked Documents list** (Book ▸ Linked Documents…) — the roll-up
  of every `assoc_uri` link, with missing files flagged.
- **Loan Repayment Calculator** (Book ▸ Loan Calculator…) — payment, totals and
  amortisation schedule; pure engine arithmetic.
- **Period-End Close** (Book ▸ Period-End Close…) — moves P&L into equity as of
  a date, one balanced closing transaction per currency, undoable, with a
  per-currency preview.
- **Tax Report Options** (Edit ▸ Tax Report Options…) — flag income/expense
  accounts, assign a tax code, and see the resulting schedule; flags round-trip
  with GnuCash via the `tax-related` / `tax-US` account slots.

**Remaining GnuCash items intentionally not built** (rarely relevant to a
personal AUD book, and none had hidden implemented functionality):

- **Import Map Editor** — GnuCash's Bayesian import-match store; FinvestLens uses
  its own rules engine instead (`≈`).
- **Online Banking Setup** — direct bank download; superseded by bank-file / PDF
  import, by design (`n/a`).
- A bundled help manual (`≈`).

**Where FinvestLens exceeds GnuCash:** AI/PDF Smart Import, saved searches and
tag search, envelope/zero-based budgets, a previewing Check & Repair with single
-action undo, and the home dashboard with alerts.
