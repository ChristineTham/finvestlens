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

    /// How many of the newest transactions a journal shows before the reader
    /// asks for more. The general ledger spans the whole book, so the journal
    /// is always windowed: a page is cheap to build and cheap to scroll, where
    /// 46k live sections were neither.
    public static let journalPageSize = 200

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

    /// How many transactions the journal for `accountID` could show in total.
    public func journalEntryCount(forAccountID accountID: GncGUID?) -> Int {
        journalTransactions(forAccountID: accountID).count
    }

    /// The newest `limit` journal entries for `accountID`, oldest first (so the
    /// newest is last, as in the register and in GnuCash). Only the entries in
    /// the window are built — the rest of the book is never materialised.
    ///
    /// Defaults to the whole journal: windowing is the caller's choice, so a
    /// report asking for a book's entries can't be silently truncated.
    public func journalEntries(forAccountID accountID: GncGUID?,
                               limit: Int = .max) -> [JournalEntry] {
        guard let book else { return [] }
        let focus = accountID.flatMap { book.account(with: $0) }
        let transactions = journalTransactions(forAccountID: accountID)
        return transactions.suffix(max(0, limit)).map { txn in
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
