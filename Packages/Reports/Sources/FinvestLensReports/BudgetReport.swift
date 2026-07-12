//
//  BudgetReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Budgeted vs actual for one account over a period.
public struct BudgetActual: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var accountName: String
    public var budgeted: Decimal
    public var actual: Decimal
    /// Budgeted minus actual (positive = under budget).
    public var remaining: Decimal
    /// Fraction of the budget spent (0…), or `nil` when nothing is budgeted.
    public var fractionUsed: Double?
    public var isOverBudget: Bool { remaining < 0 }
}

public extension FinancialReports {

    /// Budget-vs-actual for each budgeted account over `from`…`to`
    /// (`FR-BUD-02`). Actuals use the same sign-adjusted period balance as the
    /// income statement (so expense spending is positive).
    static func budgetActuals(_ book: Book, budget: Budget, from: Date, to: Date,
                              currency: Commodity) -> [BudgetActual] {
        budget.lines.compactMap { line -> BudgetActual? in
            guard let account = book.account(with: line.accountGUID) else { return nil }
            let actual = currency.round(displayBalance(of: account, in: book, from: from, to: to))
            let budgeted = currency.round(line.amount)
            let fraction: Double? = budgeted == 0 ? nil
                : NSDecimalNumber(decimal: actual).doubleValue / NSDecimalNumber(decimal: budgeted).doubleValue
            return BudgetActual(
                id: account.guid,
                accountName: account.name,
                budgeted: budgeted,
                actual: actual,
                remaining: currency.round(budgeted - actual),
                fractionUsed: fraction
            )
        }
        .sorted { $0.accountName < $1.accountName }
    }
}
