//
//  AppModel+Scheduled.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

@MainActor
extension AppModel {

    public func addScheduledTransaction(_ scheduled: ScheduledTransaction) {
        scheduledTransactions.append(scheduled)
        commitKvpCollections(named: "Add Scheduled Transaction")
    }

    public func deleteScheduledTransaction(_ id: GncGUID) {
        scheduledTransactions.removeAll { $0.id == id }
        commitKvpCollections(named: "Delete Scheduled Transaction")
    }

    /// Instances due to be entered up to `through` ("since last run").
    public func pendingScheduled(through: Date = Date()) -> [ScheduledTransactionService.PendingInstance] {
        ScheduledTransactionService.pending(scheduledTransactions, through: through)
    }

    /// Posts every due instance up to `through`, advancing each schedule's
    /// `lastPosted`. Returns the number of transactions created (`FR-SCH-03`).
    @discardableResult
    public func postDueScheduled(through: Date = Date()) -> Int {
        guard let book else { return 0 }
        var list = scheduledTransactions
        var created = 0
        for index in list.indices {
            let dueDates = list[index].dueDates(through: through)
            for date in dueDates where ScheduledTransactionService.post(list[index], date: date, into: book) != nil {
                created += 1
            }
            if let last = dueDates.last, (list[index].lastPosted ?? .distantPast) < last {
                list[index].lastPosted = last
            }
        }
        if created > 0 {
            scheduledTransactions = list
            commitKvpCollections(named: "Post Scheduled Transactions")   // persists lastPosted + refreshes
        }
        return created
    }
}
