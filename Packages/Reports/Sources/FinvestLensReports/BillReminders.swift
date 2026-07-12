//
//  BillReminders.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The state of a scheduled bill relative to today (`FR-BILL-01`).
public enum BillStatus: String, Sendable {
    case paid, overdue, dueSoon, upcoming
}

/// A single occurrence of a scheduled bill/deposit on the financial calendar
/// (`FR-PLAN-01`, `FR-BILL-01`).
public struct BillReminder: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var scheduledID: GncGUID
    public var name: String
    public var dueDate: Date
    /// Expected outflow magnitude (positive), in the schedule's currency.
    public var amount: Decimal
    public var status: BillStatus
}

public extension FinancialReports {

    /// Occurrences of scheduled outflows in `[from, to]`, each classified paid /
    /// overdue / due-soon / upcoming relative to `asOf`. "Paid" is inferred from
    /// a posted transaction with the same name within `graceDays` of the due
    /// date (`FR-BILL-01`).
    static func billReminders(
        _ book: Book,
        scheduled: [ScheduledTransaction],
        from: Date, to: Date, asOf: Date,
        dueSoonDays: Int = 7, graceDays: Int = 3
    ) -> [BillReminder] {
        var reminders: [BillReminder] = []
        let grace = TimeInterval(graceDays) * 86_400
        let dueSoon = TimeInterval(dueSoonDays) * 86_400

        for schedule in scheduled where schedule.isEnabled {
            let amount = outflowAmount(schedule, book: book)
            guard amount > 0 else { continue }
            let dates = schedule.recurrence.occurrences(since: nil, through: to).filter { $0 >= from }
            for date in dates {
                let status: BillStatus
                if isPaid(name: schedule.name, description: schedule.transactionDescription,
                          near: date, grace: grace, book: book) {
                    status = .paid
                } else if date < asOf {
                    status = .overdue
                } else if date <= asOf.addingTimeInterval(dueSoon) {
                    status = .dueSoon
                } else {
                    status = .upcoming
                }
                reminders.append(BillReminder(
                    id: UUID(), scheduledID: schedule.id, name: schedule.name,
                    dueDate: date, amount: amount, status: status))
            }
        }
        return reminders.sorted { $0.dueDate < $1.dueDate }
    }

    /// Sum of the positive postings to expense/liability accounts (the bill's
    /// cost); falls back to the largest split magnitude.
    private static func outflowAmount(_ schedule: ScheduledTransaction, book: Book) -> Decimal {
        var outflow = Decimal(0)
        for split in schedule.splits {
            guard let type = book.account(with: split.accountGUID)?.type else { continue }
            if (type == .expense || type == .liability || type == .credit), split.value > 0 {
                outflow += split.value
            }
        }
        if outflow > 0 { return outflow }
        return schedule.splits.map(\.value).map(abs).max() ?? 0
    }

    private static func isPaid(name: String, description: String, near date: Date,
                               grace: TimeInterval, book: Book) -> Bool {
        let lower = date.addingTimeInterval(-grace)
        let upper = date.addingTimeInterval(grace)
        return book.transactions.contains { txn in
            guard txn.datePosted >= lower, txn.datePosted <= upper else { return false }
            let d = txn.transactionDescription
            return d.caseInsensitiveCompare(name) == .orderedSame
                || d.caseInsensitiveCompare(description) == .orderedSame
        }
    }
}
