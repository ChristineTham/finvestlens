//
//  CashFlowForecast.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A projected balance at a point in the forecast horizon.
public struct CashFlowPoint: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var date: Date
    public var balance: Decimal
    /// The change applied at this point (0 for the starting point).
    public var change: Decimal
    /// What caused the change (scheduled transaction name, or "Today").
    public var label: String
}

public extension FinancialReports {

    /// Projects an account's balance forward from `from` to `horizon` by
    /// applying upcoming scheduled transactions that touch it (`FR-PLAN-02`).
    ///
    /// The first point is today's balance; each subsequent point applies one
    /// due occurrence.
    static func cashFlowForecast(_ book: Book, accountID: GncGUID,
                                 scheduled: [ScheduledTransaction],
                                 from: Date, horizon: Date, currency: Commodity) -> [CashFlowPoint] {
        guard book.account(with: accountID) != nil else { return [] }

        // Starting balance (raw signed quantity) up to `from`.
        var running = Decimal(0)
        for transaction in book.transactions where transaction.datePosted <= from {
            for split in transaction.splits
            where split.account?.guid == accountID && split.reconcileState != .voided {
                running += split.quantity
            }
        }

        // Upcoming occurrences that affect this account.
        struct Occurrence { var date: Date; var amount: Decimal; var name: String }
        var occurrences: [Occurrence] = []
        for schedule in scheduled where schedule.isEnabled {
            let effect = schedule.splits
                .filter { $0.accountGUID == accountID }
                .reduce(Decimal(0)) { $0 + $1.value }
            guard effect != 0 else { continue }
            for date in schedule.recurrence.occurrences(since: from, through: horizon) {
                occurrences.append(Occurrence(date: date, amount: effect, name: schedule.name))
            }
        }
        occurrences.sort { $0.date < $1.date }

        var points = [CashFlowPoint(id: UUID(), date: from, balance: currency.round(running),
                                    change: 0, label: "Today")]
        for occurrence in occurrences {
            running += occurrence.amount
            points.append(CashFlowPoint(id: UUID(), date: occurrence.date,
                                        balance: currency.round(running),
                                        change: currency.round(occurrence.amount),
                                        label: occurrence.name))
        }
        return points
    }
}
