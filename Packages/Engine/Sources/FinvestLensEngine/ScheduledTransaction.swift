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
    /// Create instances this many days before they fall due (GnuCash's
    /// advance-create horizon). 0 creates them only once due.
    public var advanceCreateDays: Int
    /// Remind this many days before an instance falls due (no transaction is
    /// created yet). GnuCash's advance-remind horizon.
    public var advanceRemindDays: Int

    public init(id: GncGUID = .random(), name: String, currency: Commodity,
                description: String = "", recurrence: Recurrence,
                splits: [ScheduledSplit] = [], lastPosted: Date? = nil, isEnabled: Bool = true,
                advanceCreateDays: Int = 0, advanceRemindDays: Int = 0) {
        self.id = id
        self.name = name
        self.currency = currency
        self.transactionDescription = description
        self.recurrence = recurrence
        self.splits = splits
        self.lastPosted = lastPosted
        self.isEnabled = isEnabled
        self.advanceCreateDays = advanceCreateDays
        self.advanceRemindDays = advanceRemindDays
    }

    // Backward-compatible decoding: books saved before the advance horizons
    // existed carry no such keys.
    private enum CodingKeys: String, CodingKey {
        case id, name, currency, transactionDescription, recurrence, splits
        case lastPosted, isEnabled, advanceCreateDays, advanceRemindDays
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(GncGUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        currency = try c.decode(Commodity.self, forKey: .currency)
        transactionDescription = try c.decodeIfPresent(String.self, forKey: .transactionDescription) ?? ""
        recurrence = try c.decode(Recurrence.self, forKey: .recurrence)
        splits = try c.decodeIfPresent([ScheduledSplit].self, forKey: .splits) ?? []
        lastPosted = try c.decodeIfPresent(Date.self, forKey: .lastPosted)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        advanceCreateDays = try c.decodeIfPresent(Int.self, forKey: .advanceCreateDays) ?? 0
        advanceRemindDays = try c.decodeIfPresent(Int.self, forKey: .advanceRemindDays) ?? 0
    }

    /// The template splits balance (sum of values is zero at the currency's fraction).
    public var isBalanced: Bool {
        let total = splits.reduce(Decimal(0)) { $0 + $1.value }
        return currency.round(total) == 0
    }

    /// Dates that are due to be generated up to `through` (occurrences after
    /// ``lastPosted``). The horizon extends by ``advanceCreateDays`` so
    /// instances can be created ahead of time, matching GnuCash's
    /// `creation_end = range_end + advance-create`. Empty when disabled.
    public func dueDates(through: Date, calendar: Calendar = .current) -> [Date] {
        guard isEnabled else { return [] }
        let horizon = advanceCreateDays > 0
            ? (calendar.date(byAdding: .day, value: advanceCreateDays, to: through) ?? through)
            : through
        return recurrence.occurrences(since: lastPosted, through: horizon)
    }

    /// Upcoming occurrences to *remind* about but not yet create: those falling
    /// between `through` (exclusive) and the advance-remind horizon. Empty when
    /// disabled or no remind window is set.
    public func remindDates(through: Date, calendar: Calendar = .current) -> [Date] {
        guard isEnabled, advanceRemindDays > 0 else { return [] }
        let createHorizon = advanceCreateDays > 0
            ? (calendar.date(byAdding: .day, value: advanceCreateDays, to: through) ?? through)
            : through
        let remindHorizon = calendar.date(byAdding: .day, value: advanceRemindDays, to: through) ?? through
        guard remindHorizon > createHorizon else { return [] }
        return recurrence.occurrences(since: createHorizon, through: remindHorizon)
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
