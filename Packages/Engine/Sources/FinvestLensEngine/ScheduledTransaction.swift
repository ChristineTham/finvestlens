//
//  ScheduledTransaction.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// One leg of a scheduled-transaction template.
public struct ScheduledSplit: Codable, Hashable, Sendable {
    public var accountGUID: GncGUID
    public var value: Decimal
    public var memo: String

    public init(accountGUID: GncGUID, value: Decimal, memo: String = "") {
        self.accountGUID = accountGUID
        self.value = value
        self.memo = memo
    }
}

/// A recurring transaction template that generates real transactions on a
/// schedule (GnuCash's Scheduled Transaction, `FR-SCH-01`).
///
/// A value type persisted with the book; instantiation into concrete
/// ``Transaction``s is handled by ``ScheduledTransactionService``.
public struct ScheduledTransaction: Identifiable, Codable, Hashable, Sendable {
    public var id: GncGUID
    public var name: String
    public var currency: Commodity
    public var transactionDescription: String
    public var recurrence: Recurrence
    public var splits: [ScheduledSplit]
    /// The date of the most recently generated occurrence, if any.
    public var lastPosted: Date?
    public var isEnabled: Bool

    public init(id: GncGUID = .random(), name: String, currency: Commodity,
                description: String = "", recurrence: Recurrence,
                splits: [ScheduledSplit] = [], lastPosted: Date? = nil, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.currency = currency
        self.transactionDescription = description
        self.recurrence = recurrence
        self.splits = splits
        self.lastPosted = lastPosted
        self.isEnabled = isEnabled
    }

    /// The template splits balance (sum of values is zero at the currency's fraction).
    public var isBalanced: Bool {
        let total = splits.reduce(Decimal(0)) { $0 + $1.value }
        return currency.round(total) == 0
    }

    /// Dates that are due to be generated up to `through` (occurrences after
    /// ``lastPosted``). Empty when disabled.
    public func dueDates(through: Date) -> [Date] {
        guard isEnabled else { return [] }
        return recurrence.occurrences(since: lastPosted, through: through)
    }
}

/// Instantiates scheduled transactions into the book ("since last run",
/// `FR-SCH-03`).
public enum ScheduledTransactionService {

    /// One pending occurrence awaiting the user's confirmation.
    public struct PendingInstance: Identifiable, Sendable {
        public let id = UUID()
        public var scheduledID: GncGUID
        public var name: String
        public var date: Date
    }

    /// All pending instances across `scheduled`, up to `through`.
    public static func pending(_ scheduled: [ScheduledTransaction], through: Date) -> [PendingInstance] {
        scheduled.flatMap { sx in
            sx.dueDates(through: through).map {
                PendingInstance(scheduledID: sx.id, name: sx.name, date: $0)
            }
        }
        .sorted { $0.date < $1.date }
    }

    /// Creates a real ``Transaction`` for `scheduled` dated `date` and adds it
    /// to `book`. Returns the created transaction, or `nil` if a split account
    /// is missing.
    @discardableResult
    public static func post(_ scheduled: ScheduledTransaction, date: Date, into book: Book) -> Transaction? {
        let transaction = Transaction(currency: scheduled.currency, datePosted: date,
                                      description: scheduled.transactionDescription)
        for templateSplit in scheduled.splits {
            guard let account = book.account(with: templateSplit.accountGUID) else { return nil }
            transaction.addSplit(account: account, value: templateSplit.value, memo: templateSplit.memo)
        }
        book.addTransaction(transaction)
        return transaction
    }
}
