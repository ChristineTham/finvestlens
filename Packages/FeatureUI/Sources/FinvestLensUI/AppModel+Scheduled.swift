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

    private static let scheduledKey = "finvestlens/scheduledTransactions"

    /// The document's scheduled transactions (persisted with the book).
    public var scheduledTransactions: [ScheduledTransaction] {
        get {
            guard let book,
                  case let .string(json)? = book.kvp[Self.scheduledKey],
                  let data = json.data(using: .utf8),
                  let list = try? JSONDecoder().decode([ScheduledTransaction].self, from: data)
            else { return [] }
            return list
        }
        set {
            guard let book else { return }
            if newValue.isEmpty {
                book.kvp[Self.scheduledKey] = nil
            } else if let data = try? JSONEncoder().encode(newValue),
                      let json = String(data: data, encoding: .utf8) {
                book.kvp[Self.scheduledKey] = .string(json)
            }
            markDirtyAndRefresh()
        }
    }

    public func addScheduledTransaction(_ scheduled: ScheduledTransaction) {
        var list = scheduledTransactions
        list.append(scheduled)
        scheduledTransactions = list
    }

    public func deleteScheduledTransaction(_ id: GncGUID) {
        scheduledTransactions.removeAll { $0.id == id }
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
        if created > 0 { scheduledTransactions = list }   // persists lastPosted + refreshes
        return created
    }
}
