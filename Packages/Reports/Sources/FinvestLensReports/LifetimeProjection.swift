//
//  LifetimeProjection.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The Lifetime Planner's long-range projection (`FR-PLAN-11`,
/// docs/planning-design.md §2) — Microsoft Money's flagship, rebuilt as a
/// deliberately **transparent annual model**: five buckets seeded from the
/// book, a page of editable assumptions, and one deterministic path. No Monte
/// Carlo, no black box; uncertainty is explored by editing assumptions.
///
/// The yearly step, in order: balances grow at their bucket's return; debts
/// accrue and amortise; income is earned and taxed (working years) or pension
/// received (retirement); spending is met from cash → investments →
/// retirement (retirement funds only from the retirement age); life events
/// land on cash; surplus savings go to investments after the retirement
/// contribution. Everything is nominal — the today's-dollars view deflates by
/// cumulative inflation at the display layer.
public enum LifetimeProjection {

    /// A one-off inflow (+) or outflow (−) in a calendar year — a house
    /// deposit, an inheritance, education, a downsize.
    public struct LifeEvent: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var year: Int
        public var amount: Decimal

        public init(id: UUID = UUID(), name: String, year: Int, amount: Decimal) {
            self.id = id
            self.name = name
            self.year = year
            self.amount = amount
        }
    }

    /// The whole editable model. Rates are annual fractions (0.06 = 6%).
    public struct Assumptions: Codable, Sendable, Equatable {
        public var birthYear: Int
        public var retirementAge: Int
        public var lifeExpectancy: Int

        public var annualIncome: Decimal
        public var incomeGrowth: Decimal
        public var annualExpenses: Decimal
        public var inflation: Decimal
        /// Spending in retirement as a share of (inflated) working expenses.
        public var retirementSpendShare: Decimal
        /// Annual contribution moved into the retirement bucket while working.
        public var retirementContribution: Decimal
        /// Annual pension/other income from retirement, in today's dollars
        /// (inflated to each year).
        public var pensionIncome: Decimal

        public var returnCash: Decimal
        public var returnInvestments: Decimal
        public var returnRetirement: Decimal
        public var returnProperty: Decimal

        /// Debt interest and the level annual repayment (repayment counts as
        /// spending until the debts bucket reaches zero).
        public var debtInterest: Decimal
        public var debtRepayment: Decimal

        public var events: [LifeEvent]

        public init(birthYear: Int, retirementAge: Int = 65, lifeExpectancy: Int = 95,
                    annualIncome: Decimal = 0, incomeGrowth: Decimal = Decimal(string: "0.03")!,
                    annualExpenses: Decimal = 0, inflation: Decimal = Decimal(string: "0.025")!,
                    retirementSpendShare: Decimal = Decimal(string: "0.75")!,
                    retirementContribution: Decimal = 0, pensionIncome: Decimal = 0,
                    returnCash: Decimal = Decimal(string: "0.03")!,
                    returnInvestments: Decimal = Decimal(string: "0.06")!,
                    returnRetirement: Decimal = Decimal(string: "0.06")!,
                    returnProperty: Decimal = Decimal(string: "0.04")!,
                    debtInterest: Decimal = Decimal(string: "0.055")!,
                    debtRepayment: Decimal = 0,
                    events: [LifeEvent] = []) {
            self.birthYear = birthYear
            self.retirementAge = retirementAge
            self.lifeExpectancy = lifeExpectancy
            self.annualIncome = annualIncome
            self.incomeGrowth = incomeGrowth
            self.annualExpenses = annualExpenses
            self.inflation = inflation
            self.retirementSpendShare = retirementSpendShare
            self.retirementContribution = retirementContribution
            self.pensionIncome = pensionIncome
            self.returnCash = returnCash
            self.returnInvestments = returnInvestments
            self.returnRetirement = returnRetirement
            self.returnProperty = returnProperty
            self.debtInterest = debtInterest
            self.debtRepayment = debtRepayment
            self.events = events
        }
    }

    /// Opening balances, seeded from the book (all positive; debts is the
    /// amount owed).
    public struct Buckets: Codable, Sendable, Equatable {
        public var cash: Decimal
        public var investments: Decimal
        public var retirement: Decimal
        public var property: Decimal
        public var debts: Decimal

        public init(cash: Decimal = 0, investments: Decimal = 0, retirement: Decimal = 0,
                    property: Decimal = 0, debts: Decimal = 0) {
            self.cash = cash
            self.investments = investments
            self.retirement = retirement
            self.property = property
            self.debts = debts
        }
    }

    public struct YearPoint: Identifiable, Sendable {
        public var id: Int { year }
        public let year: Int
        public let age: Int
        public let cash: Decimal
        public let investments: Decimal
        public let retirement: Decimal
        public let property: Decimal
        public let debts: Decimal
        public let income: Decimal
        public let tax: Decimal
        public let spending: Decimal
        /// Names of life events landing this year.
        public let notes: [String]

        public var netWorth: Decimal { cash + investments + retirement + property - debts }
        /// Divides nominal figures back to today's dollars.
        public let deflator: Decimal
    }

    public struct Result: Sendable {
        public let points: [YearPoint]
        /// The age at which drawable funds (cash+investments+retirement) run
        /// out, if they do.
        public let depletionAge: Int?
        public var endingNetWorth: Decimal { points.last?.netWorth ?? 0 }
        public var lastsTheDistance: Bool { depletionAge == nil }
    }

    public static func project(start: Buckets, assumptions: Assumptions,
                               currentYear: Int,
                               taxSettings: TaxEstimate.Settings) -> Result {
        var cash = start.cash
        var investments = start.investments
        var retirement = start.retirement
        var property = start.property
        var debts = start.debts

        var points: [YearPoint] = []
        var depletionAge: Int?
        let endAge = max(assumptions.lifeExpectancy, assumptions.retirementAge)
        let startAge = currentYear - assumptions.birthYear
        guard startAge <= endAge else {
            return Result(points: [], depletionAge: nil)
        }

        var deflator = Decimal(1)
        for offset in 0...(endAge - startAge) {
            let year = currentYear + offset
            let age = startAge + offset
            let retired = age >= assumptions.retirementAge
            if offset > 0 { deflator *= (1 + assumptions.inflation) }

            // 1. Growth on opening balances.
            cash += cash * assumptions.returnCash
            investments += investments * assumptions.returnInvestments
            retirement += retirement * assumptions.returnRetirement
            property += property * assumptions.returnProperty

            // 2. Debts accrue, then the level repayment (spending while owing).
            var debtSpending = Decimal(0)
            if debts > 0 {
                debts += debts * assumptions.debtInterest
                let repayment = min(assumptions.debtRepayment, debts)
                debts -= repayment
                debtSpending = repayment
            }

            // 3. Income and tax.
            let growth = pow(1 + assumptions.incomeGrowth, offset)
            let priceLevel = deflator
            var income: Decimal = 0
            var tax: Decimal = 0
            if !retired {
                income = assumptions.annualIncome * growth
                let estimate = TaxEstimate.estimate(
                    income: [TaxEstimate.Line(id: .random(), name: "Salary", amount: income)],
                    deductions: [], settings: taxSettings)
                tax = estimate.baseTax + estimate.levy
            } else {
                income = assumptions.pensionIncome * priceLevel
            }

            // 4. Living costs (inflated; scaled back in retirement).
            var spending = assumptions.annualExpenses * priceLevel
            if retired { spending *= assumptions.retirementSpendShare }
            spending += debtSpending

            // 5. Life events land on cash.
            let yearEvents = assumptions.events.filter { $0.year == year }
            for event in yearEvents { cash += event.amount }

            // 6. Net savings or drawdown.
            var net = income - tax - spending
            if !retired, net > 0 {
                let contribution = min(assumptions.retirementContribution, net)
                retirement += contribution
                investments += net - contribution
                net = 0
            }
            if net < 0 {
                var need = -net
                let fromCash = min(cash, need)
                cash -= fromCash; need -= fromCash
                let fromInvestments = min(investments, need)
                investments -= fromInvestments; need -= fromInvestments
                if retired {
                    let fromRetirement = min(retirement, need)
                    retirement -= fromRetirement; need -= fromRetirement
                }
                if need > 0 {
                    // Drawable funds exhausted: record it, carry the shortfall
                    // as negative cash so the chart shows the hole honestly.
                    if depletionAge == nil { depletionAge = age }
                    cash -= need
                }
            } else {
                cash += net   // retired surplus (pension > spending) rests in cash
            }

            points.append(YearPoint(year: year, age: age, cash: cash,
                                    investments: investments, retirement: retirement,
                                    property: property, debts: debts,
                                    income: income, tax: tax, spending: spending,
                                    notes: yearEvents.map(\.name),
                                    deflator: deflator))
        }
        return Result(points: points, depletionAge: depletionAge)
    }

    /// Decimal power with an integer exponent (`Foundation.pow(Decimal,Int)`
    /// exists but this keeps the intent explicit at call sites).
    private static func pow(_ base: Decimal, _ exponent: Int) -> Decimal {
        Foundation.pow(base, exponent)
    }
}

public extension FinancialReports {

    /// Seeds the Lifetime Planner's buckets from the book: every
    /// balance-sheet account's converted balance lands in a bucket by type —
    /// bank/cash/receivable → cash, securities (at market) → investments,
    /// other assets → property, liabilities → debts — except that anything
    /// under a retirement root (per `isRetirement`) goes to retirement
    /// regardless of type. The seed is a starting point the user can override.
    static func lifetimeBuckets(_ book: Book, currency: Commodity, asOf: Date,
                                isRetirement: (Account) -> Bool) -> LifetimeProjection.Buckets {
        let map = balanceMap(book, from: nil, to: asOf)
        var buckets = LifetimeProjection.Buckets()
        for account in book.accounts where !account.isPlaceholder {
            switch account.type {
            case .bank, .cash, .stock, .mutualFund, .asset,
                 .credit, .liability, .payable, .receivable:
                break
            default:
                continue
            }
            let native = map[ObjectIdentifier(account)] ?? 0
            guard native != 0,
                  let value = convert(native, of: account, in: book,
                                      to: currency, on: asOf) else { continue }
            if isRetirement(account) {
                buckets.retirement += value
                continue
            }
            switch account.type {
            case .bank, .cash, .receivable: buckets.cash += value
            case .stock, .mutualFund: buckets.investments += value
            case .asset: buckets.property += value
            case .credit, .liability, .payable: buckets.debts -= value
            default: break
            }
        }
        return buckets
    }
}
