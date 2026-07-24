//
//  DebtPlan.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The Debt Reduction Planner's monthly payoff simulation (`FR-PLAN-10`,
/// docs/planning-design.md §1) — Microsoft Money's flagship planner, as plain
/// arithmetic: each month every debt accrues interest at APR/12, receives its
/// minimum payment, and the whole remainder of the monthly budget goes to the
/// strategy's focus debt; a closed debt's payment rolls into the next.
///
/// A transparent estimate, not advice: balances come from the book, while APR
/// and minimum payments are the user's own figures.
public enum DebtPlan {

    public enum Strategy: String, CaseIterable, Sendable {
        /// Highest interest rate first — least interest paid.
        case avalanche
        /// Smallest balance first — quickest wins.
        case snowball
        /// Minimum payments only — the baseline the others are measured against.
        case minimumsOnly
    }

    /// One liability entering the plan. `balance` is positive (the amount owed).
    public struct Debt: Identifiable, Sendable {
        public let id: GncGUID
        public var name: String
        public var balance: Decimal
        /// Annual percentage rate, e.g. 0.199 for 19.9%.
        public var apr: Decimal
        public var minimumPayment: Decimal

        public init(id: GncGUID, name: String, balance: Decimal,
                    apr: Decimal, minimumPayment: Decimal) {
            self.id = id
            self.name = name
            self.balance = balance
            self.apr = apr
            self.minimumPayment = minimumPayment
        }
    }

    public struct DebtResult: Identifiable, Sendable {
        public let id: GncGUID
        public let name: String
        /// Months from the start until this debt reaches zero.
        public let payoffMonth: Int
        public let interestPaid: Decimal
    }

    public struct Result: Sendable {
        public let strategy: Strategy
        public let debts: [DebtResult]
        /// Total balance at the end of each month, from month 1.
        public let balanceSeries: [Decimal]
        public let totalInterest: Decimal
        /// Months until everything is paid off.
        public let months: Int
        /// Debts whose minimum payment doesn't even cover their monthly
        /// interest under this strategy — they would never amortise.
        public let underwater: [GncGUID]

        /// Whether the plan actually retires every debt.
        public var paysOff: Bool { underwater.isEmpty && months < DebtPlan.horizonMonths }
    }

    /// The simulation cap — 100 years, far beyond any sane plan; hitting it
    /// means the inputs never pay off.
    public static let horizonMonths = 1200

    /// Runs the simulation. `budget` is the total paid to all debts per month;
    /// under `.minimumsOnly` it is ignored and each debt just receives its
    /// minimum. Amounts round to `currency`'s fraction monthly, as a bank does.
    public static func simulate(debts: [Debt], budget: Decimal,
                                strategy: Strategy, currency: Commodity) -> Result {
        var order = debts.filter { $0.balance > 0 }
        switch strategy {
        case .avalanche:
            order.sort { ($0.apr, $1.balance) > ($1.apr, $0.balance) }
        case .snowball:
            order.sort { ($0.balance, $0.name) < ($1.balance, $1.name) }
        case .minimumsOnly:
            break
        }

        var balances: [GncGUID: Decimal] = [:]
        var interest: [GncGUID: Decimal] = [:]
        var payoff: [GncGUID: Int] = [:]
        var underwater: Set<GncGUID> = []
        for debt in order {
            balances[debt.id] = currency.round(debt.balance)
            interest[debt.id] = 0
        }

        var series: [Decimal] = []
        var month = 0
        while balances.values.contains(where: { $0 > 0 }), month < horizonMonths {
            month += 1
            // Interest first, on the running balances.
            for debt in order where balances[debt.id]! > 0 {
                let accrued = currency.round(balances[debt.id]! * debt.apr / 12)
                balances[debt.id]! += accrued
                interest[debt.id]! += accrued
                // A minimum that can't cover the interest never amortises;
                // flag it once rather than simulating forever. Extra budget
                // may still retire it under avalanche/snowball.
                if strategy == .minimumsOnly, debt.minimumPayment <= accrued {
                    underwater.insert(debt.id)
                }
            }

            // Minimums for everyone still open.
            var available = strategy == .minimumsOnly ? 0 : budget
            for debt in order where balances[debt.id]! > 0 {
                let payment = min(debt.minimumPayment, balances[debt.id]!)
                balances[debt.id]! -= payment
                available -= payment
            }

            // The remainder attacks the focus debt(s) in strategy order.
            if available > 0 {
                for debt in order where balances[debt.id]! > 0 {
                    let extra = min(available, balances[debt.id]!)
                    balances[debt.id]! -= extra
                    available -= extra
                    if available <= 0 { break }
                }
            }

            for debt in order where balances[debt.id]! <= 0 && payoff[debt.id] == nil {
                payoff[debt.id] = month
                balances[debt.id] = 0
            }
            series.append(balances.values.reduce(0, +))

            if !underwater.isEmpty { break }
        }

        let results = order.map { debt in
            DebtResult(id: debt.id, name: debt.name,
                       payoffMonth: payoff[debt.id] ?? horizonMonths,
                       interestPaid: interest[debt.id] ?? 0)
        }
        return Result(strategy: strategy, debts: results, balanceSeries: series,
                      totalInterest: results.reduce(0) { $0 + $1.interestPaid },
                      months: month, underwater: Array(underwater))
    }
}
