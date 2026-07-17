//
//  CategoryBreakdown.swift
//  FinvestLens — Reports
//
//  GnuCash's Expense Piechart, Income Piechart and Income & Expense Barchart
//  (`FR-RPT-03`) — the most-looked-at reports in a personal book, because the
//  question they answer is the everyday one: where does it all go?
//
//  Two shapes from one computation. Slices: the period's income or spending per
//  top-level category, subtrees rolled up, largest first. Months: the same
//  totals cut by calendar month for the bar chart. Both are bound to the
//  income statement — slices sum to its total, and the months sum to the
//  slices — so the three reports can never tell three stories.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One month's income and spending, for the bar chart.
public struct MonthlyFlow: Identifiable, Hashable, Sendable {
    public var id: Date { month }
    /// The first instant of the month.
    public var month: Date
    public var income: Decimal
    public var expenses: Decimal
}

public struct CategoryBreakdown: Sendable {
    public var from: Date
    public var to: Date
    public var currencyCode: String
    /// Spending per top-level expense category, subtrees rolled, largest first.
    public var expenseSlices: [ReportLine]
    /// Income per top-level income category, likewise.
    public var incomeSlices: [ReportLine]
    public var totalExpenses: Decimal
    public var totalIncome: Decimal
    /// Month-by-month totals across the period, oldest first.
    public var months: [MonthlyFlow]
}

public extension FinancialReports {

    /// Where the period's money came from and went, by category and by month
    /// (`FR-RPT-03`).
    static func categoryBreakdown(_ book: Book, from: Date, to: Date,
                                  currency: Commodity,
                                  calendar: Calendar = .current) -> CategoryBreakdown {
        // One walk for every category's period total.
        let map = balanceMap(book, from: from, to: to)

        /// A subtree's converted, presentation-signed total over the period.
        func rolled(_ account: Account) -> Decimal {
            var total = Decimal(0)
            if !account.isPlaceholder {
                let native = displayBalance(in: map, of: account)
                total = convert(native, of: account, in: book, to: currency, on: to) ?? 0
            }
            return account.children.reduce(total) { $0 + rolled($1) }
        }

        func slices(_ type: AccountType) -> ([ReportLine], Decimal) {
            var lines: [ReportLine] = []
            var total = Decimal(0)
            for top in book.rootAccount.children where top.type == type {
                let amount = currency.round(rolled(top))
                guard amount != 0 else { continue }
                lines.append(ReportLine(id: top.guid, name: top.name,
                                        fullName: top.fullName, amount: amount))
                total += amount
            }
            lines.sort { $0.amount == $1.amount ? $0.fullName < $1.fullName
                                                : $0.amount > $1.amount }
            return (lines, currency.round(total))
        }

        // Months by walking split-wise once: the slice computation converts a
        // whole subtree at the period's closing rate, which is right for "what
        // did the year cost", but a month's bar should be the month's money.
        var monthTotals: [Date: (income: Decimal, expenses: Decimal)] = [:]
        for transaction in book.transactions
        where transaction.datePosted >= from && transaction.datePosted <= to {
            for split in transaction.splits where split.reconcileState != .voided {
                guard let account = split.account else { continue }
                let isIncome = account.type == .income
                let isExpense = account.type == .expense
                guard isIncome || isExpense else { continue }
                guard let amount = convert(split.quantity, of: account, in: book,
                                           to: currency, on: transaction.datePosted)
                else { continue }
                let month = calendar.date(from: calendar.dateComponents(
                    [.year, .month], from: transaction.datePosted)) ?? transaction.datePosted
                var entry = monthTotals[month] ?? (0, 0)
                // Presentation signs: income is credit-normal, spending debit.
                if isIncome { entry.income += -amount } else { entry.expenses += amount }
                monthTotals[month] = entry
            }
        }
        let months = monthTotals
            .map { MonthlyFlow(month: $0.key,
                               income: currency.round($0.value.income),
                               expenses: currency.round($0.value.expenses)) }
            .sorted { $0.month < $1.month }

        let (expenseSlices, totalExpenses) = slices(.expense)
        let (incomeSlices, totalIncome) = slices(.income)
        return CategoryBreakdown(
            from: from, to: to, currencyCode: currency.mnemonic,
            expenseSlices: expenseSlices, incomeSlices: incomeSlices,
            totalExpenses: totalExpenses, totalIncome: totalIncome,
            months: months)
    }
}
