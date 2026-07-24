//
//  SpendingInsights.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One category, two periods (`FR-PLAN-13`).
public struct CategoryComparison: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var name: String
    public var current: Decimal
    public var prior: Decimal

    public var delta: Decimal { current - prior }
    /// nil when there is no prior base to compare against.
    public var deltaPercent: Decimal? {
        prior == 0 ? nil : (delta / abs(prior)) * 100
    }
    public var isNew: Bool { prior == 0 && current != 0 }
    public var isGone: Bool { current == 0 && prior != 0 }
}

/// The Spending Insights comparison report (docs/planning-design.md §4):
/// period vs period per top-level category, with the movers called out and a
/// deterministic plain-language summary. Bound to the category breakdown the
/// pie/bar reports use, so the stories can't diverge.
public struct SpendingInsights: Sendable {
    public var currencyCode: String
    public var from: Date
    public var to: Date
    public var priorFrom: Date
    public var priorTo: Date

    /// Spending per top-level expense category (positive = money spent).
    public var expenses: [CategoryComparison]
    /// Income per top-level income category (positive = money received).
    public var income: [CategoryComparison]

    public var totalSpendingCurrent: Decimal
    public var totalSpendingPrior: Decimal
    public var totalIncomeCurrent: Decimal
    public var totalIncomePrior: Decimal

    /// Largest spending increases (worsening) and decreases, by absolute delta.
    public var topIncreases: [CategoryComparison] {
        expenses.filter { $0.delta > 0 }.sorted { $0.delta > $1.delta }
    }
    public var topDecreases: [CategoryComparison] {
        expenses.filter { $0.delta < 0 }.sorted { $0.delta < $1.delta }
    }

    /// Deterministic plain-language sentences built from the figures —
    /// the caller supplies the currency formatter so wording and numbers
    /// can't drift apart.
    public func summary(format: (Decimal) -> String) -> [String] {
        var lines: [String] = []
        let spendDelta = totalSpendingCurrent - totalSpendingPrior

        if totalSpendingPrior != 0 {
            let percent = (abs(spendDelta) / abs(totalSpendingPrior)) * 100
            let direction = spendDelta > 0 ? "rose" : (spendDelta < 0 ? "fell" : "held steady")
            if spendDelta == 0 {
                lines.append("Spending held steady at \(format(totalSpendingCurrent)).")
            } else {
                let drivers = (spendDelta > 0 ? topIncreases : topDecreases).prefix(2)
                    .map { "\($0.name) (\($0.delta > 0 ? "+" : "−")\(format(abs($0.delta))))" }
                    .joined(separator: " and ")
                let driverClause = drivers.isEmpty ? "" : ", driven by \(drivers)"
                lines.append("Spending \(direction) \(Self.wholePercent(percent))% "
                             + "(\(format(abs(spendDelta))))\(driverClause).")
            }
        } else if totalSpendingCurrent != 0 {
            lines.append("Spending was \(format(totalSpendingCurrent)) with no prior period to compare.")
        }

        let incomeDelta = totalIncomeCurrent - totalIncomePrior
        if totalIncomePrior != 0, incomeDelta != 0 {
            let percent = (abs(incomeDelta) / abs(totalIncomePrior)) * 100
            lines.append("Income \(incomeDelta > 0 ? "rose" : "fell") "
                         + "\(Self.wholePercent(percent))% (\(format(abs(incomeDelta)))).")
        }

        let counter = topDecreases.first
        if let counter, spendDelta > 0, counter.delta < 0 {
            lines.append("\(counter.name) fell \(format(abs(counter.delta))).")
        }

        let fresh = expenses.filter(\.isNew).sorted { $0.current > $1.current }
        if let biggest = fresh.first {
            lines.append("New this period: \(biggest.name) (\(format(biggest.current)))"
                         + (fresh.count > 1 ? " and \(fresh.count - 1) more." : "."))
        }

        let saved = totalIncomeCurrent - totalSpendingCurrent
        if totalIncomeCurrent > 0 {
            let rate = (saved / totalIncomeCurrent) * 100
            lines.append(saved >= 0
                ? "You kept \(format(saved)) — a \(Self.wholePercent(rate))% saving rate."
                : "Spending exceeded income by \(format(abs(saved))).")
        }
        return lines
    }

    public static func wholePercent(_ value: Decimal) -> String {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 0, .plain)
        return "\(output)"
    }
}

public extension FinancialReports {

    /// Compares two periods category by category (`FR-PLAN-13`), reusing the
    /// category-breakdown walk so every figure ties to the pie/bar reports.
    static func spendingInsights(_ book: Book, from: Date, to: Date,
                                 priorFrom: Date, priorTo: Date,
                                 currency: Commodity,
                                 calendar: Calendar = .current) -> SpendingInsights {
        let current = categoryBreakdown(book, from: from, to: to,
                                        currency: currency, calendar: calendar)
        let prior = categoryBreakdown(book, from: priorFrom, to: priorTo,
                                      currency: currency, calendar: calendar)

        func join(_ now: [ReportLine], _ then: [ReportLine]) -> [CategoryComparison] {
            var byID: [GncGUID: CategoryComparison] = [:]
            for line in now {
                byID[line.id] = CategoryComparison(id: line.id, name: line.name,
                                                   current: line.amount, prior: 0)
            }
            for line in then {
                if var existing = byID[line.id] {
                    existing.prior = line.amount
                    byID[line.id] = existing
                } else {
                    byID[line.id] = CategoryComparison(id: line.id, name: line.name,
                                                       current: 0, prior: line.amount)
                }
            }
            return byID.values.sorted {
                max(abs($0.current), abs($0.prior)) > max(abs($1.current), abs($1.prior))
            }
        }

        return SpendingInsights(
            currencyCode: currency.mnemonic,
            from: from, to: to, priorFrom: priorFrom, priorTo: priorTo,
            expenses: join(current.expenseSlices, prior.expenseSlices),
            income: join(current.incomeSlices, prior.incomeSlices),
            totalSpendingCurrent: current.totalExpenses,
            totalSpendingPrior: prior.totalExpenses,
            totalIncomeCurrent: current.totalIncome,
            totalIncomePrior: prior.totalIncome)
    }
}
