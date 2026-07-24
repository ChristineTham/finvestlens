//
//  WellbeingScore.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The financial wellbeing score (`FR-PLAN-16`, docs/planning-design.md §5):
/// four transparent components, 0–25 points each, from the last three full
/// months against the prior three. Every component exposes its raw inputs so
/// the UI can show the exact arithmetic — an indicator, not a judgement, and
/// never a black box. Thresholds (20% savings rate, 6-month buffer, 60% debt
/// ratio, +25% trend) are common guidance, kept in one place here.
public enum WellbeingScore {

    public enum Component: String, CaseIterable, Sendable {
        case savingsRate
        case cashBuffer
        case debtPressure
        case spendingTrend

        public var title: String {
            switch self {
            case .savingsRate: "Savings rate"
            case .cashBuffer: "Cash buffer"
            case .debtPressure: "Debt pressure"
            case .spendingTrend: "Spending trend"
            }
        }
    }

    public struct ComponentScore: Identifiable, Sendable {
        public var id: String { component.rawValue }
        public let component: Component
        /// 0–25.
        public let points: Decimal
        /// The measured value (rate, months, ratio, or % change).
        public let measure: Decimal
        /// The measure at which full marks are awarded.
        public let target: Decimal
    }

    public struct Inputs: Sendable {
        public var income3Months: Decimal
        public var spending3Months: Decimal
        public var priorSpending3Months: Decimal
        public var liquidBalance: Decimal
        public var monthlySpend: Decimal
        public var nonMortgageDebt: Decimal
        public var annualIncome: Decimal

        public init(income3Months: Decimal, spending3Months: Decimal,
                    priorSpending3Months: Decimal, liquidBalance: Decimal,
                    monthlySpend: Decimal, nonMortgageDebt: Decimal,
                    annualIncome: Decimal) {
            self.income3Months = income3Months
            self.spending3Months = spending3Months
            self.priorSpending3Months = priorSpending3Months
            self.liquidBalance = liquidBalance
            self.monthlySpend = monthlySpend
            self.nonMortgageDebt = nonMortgageDebt
            self.annualIncome = annualIncome
        }
    }

    public struct Result: Sendable {
        public let components: [ComponentScore]
        public var total: Int {
            let sum = components.reduce(Decimal(0)) { $0 + $1.points }
            return NSDecimalNumber(decimal: sum).intValue
        }
    }

    public static func compute(_ inputs: Inputs) -> Result {
        var components: [ComponentScore] = []

        // Savings rate: full marks at ≥20% of income kept.
        let savingsRate: Decimal = inputs.income3Months > 0
            ? (inputs.income3Months - inputs.spending3Months) / inputs.income3Months : 0
        components.append(ComponentScore(
            component: .savingsRate,
            points: scale(savingsRate, from: 0, to: Decimal(string: "0.20")!),
            measure: savingsRate, target: Decimal(string: "0.20")!))

        // Cash buffer: months of spending covered by liquid funds; full at 6.
        let bufferMonths: Decimal = inputs.monthlySpend > 0
            ? inputs.liquidBalance / inputs.monthlySpend
            : (inputs.liquidBalance > 0 ? 6 : 0)
        components.append(ComponentScore(
            component: .cashBuffer,
            points: scale(bufferMonths, from: 0, to: 6),
            measure: bufferMonths, target: 6))

        // Debt pressure: non-mortgage debt over annual income; full marks at
        // zero, none from 60% up (inverted scale).
        let debtRatio: Decimal = inputs.annualIncome > 0
            ? inputs.nonMortgageDebt / inputs.annualIncome
            : (inputs.nonMortgageDebt > 0 ? 1 : 0)
        components.append(ComponentScore(
            component: .debtPressure,
            points: 25 - scale(debtRatio, from: 0, to: Decimal(string: "0.60")!),
            measure: debtRatio, target: 0))

        // Spending trend: flat or falling scores full; +25% growth scores zero.
        let trend: Decimal = inputs.priorSpending3Months > 0
            ? (inputs.spending3Months - inputs.priorSpending3Months) / inputs.priorSpending3Months
            : 0
        components.append(ComponentScore(
            component: .spendingTrend,
            points: 25 - scale(trend, from: 0, to: Decimal(string: "0.25")!),
            measure: trend, target: 0))

        return Result(components: components)
    }

    /// Linear 0–25 between `from` and `to`, clamped.
    private static func scale(_ value: Decimal, from floor: Decimal, to target: Decimal) -> Decimal {
        guard target != floor else { return value >= target ? 25 : 0 }
        let fraction = (value - floor) / (target - floor)
        let clamped = min(max(fraction, 0), 1)
        var raw = clamped * 25
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 1, .plain)
        return rounded
    }
}
