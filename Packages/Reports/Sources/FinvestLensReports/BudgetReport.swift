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
    /// Rollover carried in from the prior period (0 unless the line rolls over).
    public var carryover: Decimal
    public var actual: Decimal
    /// Budgeted + carryover − actual (positive = under budget).
    public var remaining: Decimal
    /// Fraction of the effective budget spent (0…), or `nil` when nothing is
    /// budgeted.
    public var fractionUsed: Double?
    /// Budget after carryover.
    public var effectiveBudget: Decimal { budgeted + carryover }
    public var isOverBudget: Bool { remaining < 0 }
}

/// A zero-based summary: is every budgeted dollar of income assigned to an
/// expense/saving? (`FR-PLAN-04`).
public struct BudgetSummary: Sendable {
    public var incomeBudget: Decimal
    public var expenseBudget: Decimal
    /// Income budget minus expense budget (0 = fully allocated / zero-based).
    public var unallocated: Decimal
}

public extension FinancialReports {

    /// Budget-vs-actual for each budgeted account over `from`…`to`
    /// (`FR-BUD-02`). Actuals use the same sign-adjusted period balance as the
    /// income statement (so expense spending is positive). For rollover lines,
    /// the unspent remainder of the immediately-preceding period of equal length
    /// is carried into the effective budget.
    /// - Parameter period: when given, budgeted amounts use that period's value
    ///   (GnuCash's per-period budget); `nil` uses each line's flat amount.
    static func budgetActuals(_ book: Book, budget: Budget, from: Date, to: Date,
                              currency: Commodity, period: Int? = nil) -> [BudgetActual] {
        let length = to.timeIntervalSince(from)
        let priorTo = from
        let priorFrom = from.addingTimeInterval(-length)

        return budget.lines.compactMap { line -> BudgetActual? in
            guard let account = book.account(with: line.accountGUID) else { return nil }
            let actual = currency.round(displayBalance(of: account, in: book, from: from, to: to))
            let budgeted = currency.round(period.map { line.amount(inPeriod: $0) } ?? line.amount)

            var carryover = Decimal(0)
            if line.rollover {
                let priorActual = currency.round(displayBalance(of: account, in: book, from: priorFrom, to: priorTo))
                carryover = currency.round(budgeted - priorActual)
            }
            let effective = budgeted + carryover
            let fraction: Double? = effective == 0 ? nil
                : NSDecimalNumber(decimal: actual).doubleValue / NSDecimalNumber(decimal: effective).doubleValue
            return BudgetActual(
                id: account.guid,
                accountName: account.name,
                budgeted: budgeted,
                carryover: carryover,
                actual: actual,
                remaining: currency.round(effective - actual),
                fractionUsed: fraction
            )
        }
        .sorted { $0.accountName < $1.accountName }
    }

    /// Zero-based summary of a budget: total income budget vs total expense
    /// budget, and what's left to allocate (`FR-PLAN-04`).
    static func budgetSummary(_ book: Book, budget: Budget, currency: Commodity) -> BudgetSummary {
        var income = Decimal(0)
        var expense = Decimal(0)
        for line in budget.lines {
            guard let type = book.account(with: line.accountGUID)?.type else { continue }
            if type == .income { income += line.amount }
            else if type == .expense { expense += line.amount }
        }
        return BudgetSummary(incomeBudget: currency.round(income),
                             expenseBudget: currency.round(expense),
                             unallocated: currency.round(income - expense))
    }
}
