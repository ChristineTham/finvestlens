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

    private static let budgetsKey = "finvestlens/budgets"

    /// The document's budgets (persisted with the book).
    public var budgets: [Budget] {
        get {
            guard let book,
                  case let .string(json)? = book.kvp[Self.budgetsKey],
                  let data = json.data(using: .utf8),
                  let list = try? JSONDecoder().decode([Budget].self, from: data)
            else { return [] }
            return list
        }
        set {
            guard let book else { return }
            if newValue.isEmpty {
                book.kvp[Self.budgetsKey] = nil
            } else if let data = try? JSONEncoder().encode(newValue),
                      let json = String(data: data, encoding: .utf8) {
                book.kvp[Self.budgetsKey] = .string(json)
            }
            markDirtyAndRefresh()
        }
    }

    public func addBudget(_ budget: Budget) {
        var list = budgets
        list.append(budget)
        budgets = list
    }

    public func updateBudget(_ budget: Budget) {
        var list = budgets
        if let index = list.firstIndex(where: { $0.id == budget.id }) {
            list[index] = budget
            budgets = list
        }
    }

    public func deleteBudget(_ id: GncGUID) {
        budgets.removeAll { $0.id == id }
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
