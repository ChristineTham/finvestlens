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

    /// Zero-based summary for a budget (`FR-PLAN-04`).
    public func budgetSummary(_ budget: Budget) -> BudgetSummary? {
        guard let book else { return nil }
        return FinancialReports.budgetSummary(book, budget: budget, currency: reportCurrency)
    }

    /// Toggles envelope rollover for one account's budget line.
    public func setBudgetRollover(_ rollover: Bool, for accountID: GncGUID, in budgetID: GncGUID) {
        guard let index = budgets.firstIndex(where: { $0.id == budgetID }) else { return }
        budgets[index].setRollover(rollover, for: accountID)
        commitKvpCollections()
    }

    /// Auto-replenish (auto-budget): sets each income/expense line to the
    /// average actual over the last `months` complete months (`FR-BUD-03`).
    public func autoBudget(_ budgetID: GncGUID, months: Int = 3) {
        guard let book, let index = budgets.firstIndex(where: { $0.id == budgetID }), months > 0 else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = Date()
        guard let thisMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        else { return }

        // Windows for the last `months` complete months (excluding the current one).
        var windows: [(Date, Date)] = []
        for back in 1...months {
            guard let start = calendar.date(byAdding: .month, value: -back, to: thisMonthStart),
                  let next = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            windows.append((start, next.addingTimeInterval(-1)))
        }
        guard !windows.isEmpty else { return }

        var budget = budgets[index]
        for line in budget.lines {
            guard let account = book.account(with: line.accountGUID) else { continue }
            let total = windows.reduce(Decimal(0)) { sum, window in
                sum + FinancialReports.periodActual(of: account, in: book, from: window.0, to: window.1)
            }
            let average = reportCurrency.round(total / Decimal(windows.count))
            budget.setAmount(average, for: line.accountGUID)
        }
        budgets[index] = budget
        commitKvpCollections()
    }
}
