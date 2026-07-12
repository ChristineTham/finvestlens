//
//  AppModel+Journal.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One leg shown in a journal-style register row.
public struct JournalLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var accountName: String
    public var amount: Decimal
    /// `true` when this leg posts to the register's focused account.
    public var isFocusAccount: Bool
}

/// A transaction shown with all its legs (journal / general-ledger style).
public struct JournalEntry: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var date: Date
    public var description: String
    public var currencyCode: String
    public var lines: [JournalLine]
}

/// How the register presents transactions (`FR-REG-01`).
public enum RegisterStyle: String, CaseIterable, Identifiable, Sendable {
    case basic = "Basic"
    case journal = "Journal"
    case generalLedger = "General Ledger"
    public var id: String { rawValue }
}

@MainActor
extension AppModel {

    /// Journal entries for `accountID` (its transactions), or every transaction
    /// when `accountID` is `nil` (general ledger). Sorted oldest first.
    public func journalEntries(forAccountID accountID: GncGUID?) -> [JournalEntry] {
        guard let book else { return [] }
        let focus = accountID.flatMap { book.account(with: $0) }
        let transactions = book.transactions
            .filter { txn in
                guard let focus else { return true }
                return txn.splits.contains { $0.account === focus }
            }
            .sorted { $0.datePosted < $1.datePosted }

        return transactions.map { txn in
            JournalEntry(
                id: txn.guid, date: txn.datePosted,
                description: txn.transactionDescription,
                currencyCode: txn.currency.mnemonic,
                lines: txn.splits.map { split in
                    JournalLine(
                        id: split.guid,
                        accountName: split.account?.name ?? "—",
                        amount: split.value,
                        isFocusAccount: focus != nil && split.account === focus)
                })
        }
    }
}
