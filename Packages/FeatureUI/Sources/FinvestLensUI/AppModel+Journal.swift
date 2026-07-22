//
//  AppModel+Journal.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One line of a journal register: either a transaction's heading or one of
/// its legs. A journal is a register with several rows per transaction (as in
/// GnuCash), so it is a flat list of uniform rows rather than nested sections —
/// which is what lets it be a `Table`, and lets a jump to either end be
/// instant no matter how far away it is.
public struct JournalRow: Identifiable, Hashable, Sendable {
    /// The transaction's GUID for a heading, the split's for a leg.
    public let id: GncGUID
    public var transactionID: GncGUID
    public var isHeading: Bool
    /// Set on headings only.
    public var date: Date?
    /// The description on a heading, the account name on a leg.
    public var text: String
    /// Set on legs only.
    public var amount: Decimal?
    public var currencyCode: String
    /// `true` when this leg posts to the register's focused account.
    public var isFocusAccount: Bool
    /// The transaction's notes (headings only) — shown under the description in
    /// the journal styles.
    public var notes: String = ""
    /// The split's memo (legs only) — shown under the account name.
    public var memo: String = ""
    /// The split's action (legs only) — GnuCash's per-leg Action field.
    public var action: String = ""
    /// The split's reconcile glyph (legs only): n/c/y/f/v, as in the Basic
    /// register — empty on headings.
    public var reconcile: String = ""
    /// The focused account's balance as of this leg (single-account journals
    /// only; `nil` on headings, other accounts' legs, and the general ledger).
    /// Gives the journal styles the same Balance column as Basic, so switching
    /// styles doesn't reflow the trailing columns.
    public var runningBalance: Decimal?

    /// The secondary detail line for this row: notes on a heading, action and
    /// memo on a leg. Empty when there is nothing to say.
    public var detailLine: String {
        if isHeading { return notes }
        let action = action.trimmingCharacters(in: .whitespaces)
        let memo = memo.trimmingCharacters(in: .whitespaces)
        switch (action.isEmpty, memo.isEmpty) {
        case (false, false): return "\(action) · \(memo)"
        case (false, true): return action
        case (true, false): return memo
        case (true, true): return ""
        }
    }
}

/// One row of the Basic / Auto-Split register table: a transaction row (the
/// focus account's split, exactly as Basic shows it), or — in Auto-Split — one
/// leg of the expanded transaction shown beneath it.
public struct AutoSplitRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    /// The Basic register row; `nil` for an expanded leg.
    public let main: RegisterRow?
    /// Leg fields (empty on main rows).
    public let legAccount: String
    public let legMemo: String
    public let legReconcile: String
    public let legAmount: Decimal
    public let legCurrencyCode: String

    init(main: RegisterRow) {
        id = main.id
        self.main = main
        legAccount = ""
        legMemo = ""
        legReconcile = ""
        legAmount = 0
        legCurrencyCode = ""
    }

    init(legID: GncGUID, account: String, memo: String, reconcile: String,
         amount: Decimal, currencyCode: String) {
        id = legID
        main = nil
        legAccount = account
        legMemo = memo
        legReconcile = reconcile
        legAmount = amount
        legCurrencyCode = currencyCode
    }

    // Sort handles for the table's sortable headers. Never applied to reorder
    // rows — the model sorts; see `tableSortOrder` in RegisterView.
    public var date: Date { main?.date ?? .distantFuture }
    public var description: String { main?.description ?? legAccount }
    public var amount: Decimal { main?.amount ?? legAmount }
}

/// How the register presents transactions (`FR-REG-01`).
public enum RegisterStyle: String, CaseIterable, Identifiable, Sendable {
    case basic = "Basic"
    /// GnuCash's Auto-Split Ledger: one line per transaction, and the selected
    /// one opened out into its legs.
    case autoSplit = "Auto-Split"
    case journal = "Journal"
    case generalLedger = "General Ledger"
    public var id: String { rawValue }
}

@MainActor
extension AppModel {

    /// Every row of the journal for `accountID` (the general ledger when it is
    /// `nil`), oldest first: a heading per transaction followed by its legs.
    ///
    /// Cached until the book changes. Building ~140k rows for the whole book is
    /// a fraction of a second once, but doing it per body pass is not — and the
    /// rows are uniform, so the whole journal can be a `Table` and no longer
    /// needs to be windowed to stay responsive.
    public func journalRows(forAccountID accountID: GncGUID?) -> [JournalRow] {
        if let cached = journalRowCache[accountID] { return cached }
        guard let book else { return [] }
        let focus = accountID.flatMap { book.account(with: $0) }
        var rows: [JournalRow] = []
        var focusBalance = Decimal(0)
        rows.reserveCapacity(journalTransactions(forAccountID: accountID).count * 3)
        for txn in journalTransactions(forAccountID: accountID) {
            rows.append(JournalRow(
                id: txn.guid, transactionID: txn.guid, isHeading: true,
                date: txn.datePosted, text: txn.transactionDescription,
                amount: nil, currencyCode: txn.currency.mnemonic, isFocusAccount: false,
                notes: txn.notes))
            for split in txn.splits {
                let isFocus = focus != nil && split.account === focus
                if isFocus { focusBalance += split.value }
                rows.append(JournalRow(
                    id: split.guid, transactionID: txn.guid, isHeading: false,
                    date: nil, text: split.account?.name ?? "—",
                    amount: split.value, currencyCode: txn.currency.mnemonic,
                    isFocusAccount: isFocus,
                    memo: split.memo, action: split.action,
                    reconcile: split.reconcileState.rawValue,
                    runningBalance: isFocus ? focusBalance : nil))
            }
        }
        journalRowCache[accountID] = rows
        return rows
    }

    /// GnuCash's Auto-Split Ledger (`FR-REG-03`): exactly the Basic register —
    /// same rows, columns and running balance — with the transaction you are
    /// looking at opened out into its legs beneath its row.
    ///
    /// A main row is a ``RegisterRow`` (the focus account's split); a leg row is
    /// one split of the expanded transaction. Legs posting to accounts already
    /// shown as main rows are skipped — they are on screen, and a split GUID
    /// can only appear once in the table.
    public func autoSplitRows(expanding transactionID: GncGUID?) -> [AutoSplitRow] {
        let rows = registerRows
        guard let transactionID, let txn = book?.transaction(with: transactionID) else {
            return rows.map(AutoSplitRow.init(main:))
        }
        let expandedIDs = Set(txn.splits.map(\.guid))
        let mainIDs = Set(rows.map(\.id))
        var out: [AutoSplitRow] = []
        out.reserveCapacity(rows.count + txn.splits.count)
        var inserted = false
        for row in rows {
            out.append(AutoSplitRow(main: row))
            if !inserted, expandedIDs.contains(row.id) {
                inserted = true
                for split in txn.splits where !mainIDs.contains(split.guid) {
                    out.append(AutoSplitRow(
                        legID: split.guid,
                        account: split.account?.fullName ?? "—",
                        memo: split.memo,
                        reconcile: split.reconcileState.rawValue,
                        amount: split.value,
                        currencyCode: txn.currency.mnemonic))
                }
            }
        }
        return out
    }

    /// Transactions for `accountID` (its postings), or every transaction when
    /// `accountID` is `nil` (general ledger). Sorted oldest first, and cached
    /// until the book changes — filtering and sorting the whole book on every
    /// body pass is what made the general ledger unusable.
    func journalTransactions(forAccountID accountID: GncGUID?) -> [Transaction] {
        if let cached = journalTransactionCache[accountID] { return cached }
        guard let book else { return [] }
        let focus = accountID.flatMap { book.account(with: $0) }
        let transactions = book.transactions
            .filter { txn in
                guard let focus else { return true }
                return txn.splits.contains { $0.account === focus }
            }
            .sorted { $0.datePosted < $1.datePosted }
        journalTransactionCache[accountID] = transactions
        return transactions
    }

    /// How many transactions the journal for `accountID` holds.
    public func journalEntryCount(forAccountID accountID: GncGUID?) -> Int {
        journalTransactions(forAccountID: accountID).count
    }

    /// The journal row a jump lands on: the oldest heading, or the newest
    /// transaction's last leg. Read off the cached rows, so asking is free.
    public func journalEdgeRowID(forAccountID accountID: GncGUID?, newest: Bool) -> GncGUID? {
        let rows = journalRows(forAccountID: accountID)
        return newest ? rows.last?.id : rows.first?.id
    }
}
