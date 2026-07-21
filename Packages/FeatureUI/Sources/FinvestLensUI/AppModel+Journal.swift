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
        rows.reserveCapacity(journalTransactions(forAccountID: accountID).count * 3)
        for txn in journalTransactions(forAccountID: accountID) {
            rows.append(JournalRow(
                id: txn.guid, transactionID: txn.guid, isHeading: true,
                date: txn.datePosted, text: txn.transactionDescription,
                amount: nil, currencyCode: txn.currency.mnemonic, isFocusAccount: false,
                notes: txn.notes))
            for split in txn.splits {
                rows.append(JournalRow(
                    id: split.guid, transactionID: txn.guid, isHeading: false,
                    date: nil, text: split.account?.name ?? "—",
                    amount: split.value, currencyCode: txn.currency.mnemonic,
                    isFocusAccount: focus != nil && split.account === focus,
                    memo: split.memo, action: split.action))
            }
        }
        journalRowCache[accountID] = rows
        return rows
    }

    /// GnuCash's Auto-Split Ledger (`FR-REG-03`): one line per transaction, with
    /// the one you are looking at opened out into its legs.
    ///
    /// The style sits between the other two and is the one people actually keep
    /// on: Basic never shows you a multi-split transaction's insides, and
    /// Journal shows everyone's at once, which on a real account is mostly rows
    /// you did not ask about.
    ///
    /// Filtered from the journal's own cached rows, so switching style or moving
    /// the selection costs a pass over an array rather than a rebuild.
    public func autoSplitRows(forAccountID accountID: GncGUID?,
                              expanding transactionID: GncGUID?) -> [JournalRow] {
        journalRows(forAccountID: accountID).filter { row in
            row.isHeading || row.transactionID == transactionID
        }
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
