//
//  TaxEstimate.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The tax estimator (`FR-PLAN-12`, docs/planning-design.md §3): progressive
/// bracket arithmetic over the book's tax-tagged figures. The bracket table is
/// **data, not law** — seeded with Australian resident rates, edited by the
/// user as rules change — and the result is an estimate from the user's own
/// books, never advice.
public enum TaxEstimate {

    /// One marginal bracket: the rate applying to income **over** `over`.
    public struct Bracket: Codable, Sendable, Equatable, Identifiable {
        public var id: Decimal { over }
        public var over: Decimal
        public var rate: Decimal

        public init(over: Decimal, rate: Decimal) {
            self.over = over
            self.rate = rate
        }
    }

    /// The editable model: brackets plus the flat levy and the long-term
    /// capital-gains discount share.
    public struct Settings: Codable, Sendable, Equatable {
        public var brackets: [Bracket]
        /// A flat levy on taxable income (Medicare levy: 0.02). The real levy
        /// has low-income phase-ins this deliberately ignores — documented on
        /// the estimate screen.
        public var levyRate: Decimal
        /// The share of long-term gains excluded (AU CGT discount: 0.5).
        public var longTermDiscount: Decimal

        public init(brackets: [Bracket], levyRate: Decimal, longTermDiscount: Decimal) {
            self.brackets = brackets.sorted { $0.over < $1.over }
            self.levyRate = levyRate
            self.longTermDiscount = longTermDiscount
        }

        /// Australian resident rates for the financial year **ending** in
        /// `year` (e.g. 2027 = FY 2026–27, whose first taxed bracket is 15%
        /// under the legislated 2026 cut; 16% for FY 2024–25/2025–26).
        public static func australian(financialYearEnding year: Int) -> Settings {
            let firstRate: Decimal
            switch year {
            case ..<2027: firstRate = Decimal(string: "0.16")!
            case 2027: firstRate = Decimal(string: "0.15")!
            default: firstRate = Decimal(string: "0.14")!
            }
            return Settings(brackets: [
                Bracket(over: 0, rate: 0),
                Bracket(over: 18_200, rate: firstRate),
                Bracket(over: 45_000, rate: Decimal(string: "0.30")!),
                Bracket(over: 135_000, rate: Decimal(string: "0.37")!),
                Bracket(over: 190_000, rate: Decimal(string: "0.45")!),
            ], levyRate: Decimal(string: "0.02")!, longTermDiscount: Decimal(string: "0.5")!)
        }
    }

    /// One source line feeding the estimate (an account and its FY total).
    public struct Line: Identifiable, Sendable {
        public let id: GncGUID
        public var name: String
        public var amount: Decimal

        public init(id: GncGUID, name: String, amount: Decimal) {
            self.id = id
            self.name = name
            self.amount = amount
        }
    }

    /// One bracket's contribution to the tax bill.
    public struct BracketTax: Identifiable, Sendable {
        public var id: Decimal { bracket.over }
        public let bracket: Bracket
        /// The slice of taxable income falling in this bracket.
        public let taxedAmount: Decimal
        public let tax: Decimal
    }

    public struct Result: Sendable {
        public let income: [Line]
        public let deductions: [Line]
        public let assessableIncome: Decimal
        public let totalDeductions: Decimal
        /// Gains before the discount: short, long, and unknown-holding.
        public let shortTermGains: Decimal
        public let longTermGains: Decimal
        public let otherGains: Decimal
        /// Long-term gains after the discount + the rest, floored at zero
        /// (losses aren't applied against other income here — carried forward
        /// in reality; documented on-screen).
        public let netCapitalGains: Decimal
        public let taxableIncome: Decimal
        public let bracketTaxes: [BracketTax]
        public let baseTax: Decimal
        public let levy: Decimal
        public let frankingCredits: Decimal
        public let withheld: Decimal
        /// Positive = estimated amount owing, negative = estimated refund.
        public let balance: Decimal
    }

    public static func estimate(income: [Line], deductions: [Line],
                                shortTermGains: Decimal = 0,
                                longTermGains: Decimal = 0,
                                otherGains: Decimal = 0,
                                frankingCredits: Decimal = 0,
                                withheld: Decimal = 0,
                                settings: Settings) -> Result {
        let assessable = income.reduce(0) { $0 + $1.amount }
        let deductible = deductions.reduce(0) { $0 + $1.amount }

        // Net gains: the discount excludes a share of (positive) long-term
        // gains; a net capital loss doesn't reduce ordinary income.
        let discountedLong = longTermGains > 0
            ? longTermGains * (1 - settings.longTermDiscount) : longTermGains
        let netGains = max(0, discountedLong + shortTermGains + otherGains)

        let taxable = max(0, assessable + netGains - deductible)

        // Progressive brackets: each rate applies to the slice between its
        // threshold and the next.
        var bracketTaxes: [BracketTax] = []
        let brackets = settings.brackets.sorted { $0.over < $1.over }
        for (index, bracket) in brackets.enumerated() {
            guard taxable > bracket.over else { break }
            let upper = index + 1 < brackets.count ? brackets[index + 1].over : taxable
            let slice = min(taxable, upper) - bracket.over
            guard slice > 0 else { continue }
            let tax = roundCents(slice * bracket.rate)
            bracketTaxes.append(BracketTax(bracket: bracket, taxedAmount: slice, tax: tax))
        }
        let baseTax = bracketTaxes.reduce(0) { $0 + $1.tax }
        let levy = roundCents(taxable * settings.levyRate)

        return Result(income: income, deductions: deductions,
                      assessableIncome: assessable, totalDeductions: deductible,
                      shortTermGains: shortTermGains, longTermGains: longTermGains,
                      otherGains: otherGains, netCapitalGains: netGains,
                      taxableIncome: taxable, bracketTaxes: bracketTaxes,
                      baseTax: baseTax, levy: levy,
                      frankingCredits: frankingCredits, withheld: withheld,
                      balance: baseTax + levy - frankingCredits - withheld)
    }

    private static func roundCents(_ value: Decimal) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 2, .bankers)
        return output
    }
}
