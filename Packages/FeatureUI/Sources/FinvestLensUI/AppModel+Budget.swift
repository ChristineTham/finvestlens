//
//  AppModel+Budget.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

@MainActor
extension AppModel {

    public func addBudget(_ budget: Budget) {
        budgets.append(budget)
        commitKvpCollections()
    }

    public func updateBudget(_ budget: Budget) {
        guard let index = budgets.firstIndex(where: { $0.id == budget.id }) else { return }
        budgets[index] = budget
        commitKvpCollections()
    }

    public func deleteBudget(_ id: GncGUID) {
        budgets.removeAll { $0.id == id }
        commitKvpCollections()
    }

    /// Budget-vs-actual for the calendar month containing `month` (`FR-BUD-02`).
    public func budgetActuals(_ budget: Budget, month: Date = Date()) -> [BudgetActual] {
        guard let book else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = calendar.dateComponents([.year, .month], from: month)
        guard let start = calendar.date(from: components),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: start)
        else { return [] }
        let end = nextMonth.addingTimeInterval(-1)
        return FinancialReports.budgetActuals(book, budget: budget, from: start, to: end,
                                              currency: reportCurrency)
    }
}
