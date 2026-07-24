//
//  PlanningTests.swift
//  FinvestLens — Reports
//
//  P9 calculators: tax estimate, lifetime projection, spending insights,
//  wellbeing score (docs/planning-design.md).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = m; c.day = d
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

@Suite("Tax estimate")
struct TaxEstimateTests {

    private let settings = TaxEstimate.Settings.australian(financialYearEnding: 2027)

    @Test("Progressive brackets compute the FY 2026–27 schedule exactly")
    func brackets() {
        // $100,000 taxable: 0 to 18,200 → nil; 26,800 @ 15% = 4,020;
        // 55,000 @ 30% = 16,500. Base tax 20,520; levy 2% = 2,000.
        let result = TaxEstimate.estimate(
            income: [.init(id: .random(), name: "Salary", amount: 100_000)],
            deductions: [], settings: settings)
        #expect(result.taxableIncome == 100_000)
        #expect(result.baseTax == Decimal(string: "20520"))
        #expect(result.levy == Decimal(string: "2000"))
        #expect(result.balance == Decimal(string: "22520"))
        #expect(result.bracketTaxes.count == 3)   // 0%, 15%, 30% slices
    }

    @Test("Deductions, franking credits, and withholding reduce the balance")
    func offsets() {
        let result = TaxEstimate.estimate(
            income: [.init(id: .random(), name: "Salary", amount: 100_000)],
            deductions: [.init(id: .random(), name: "Work expenses", amount: 10_000)],
            frankingCredits: 1_500, withheld: 20_000, settings: settings)
        #expect(result.taxableIncome == 90_000)
        // 26,800 @ 15% + 45,000 @ 30% = 4,020 + 13,500 = 17,520; levy 1,800.
        #expect(result.baseTax == Decimal(string: "17520"))
        #expect(result.balance == Decimal(string: "17520")! + 1_800 - 1_500 - 20_000)
        #expect(result.balance < 0)   // a refund
    }

    @Test("Long-term gains get the discount; net capital losses don't offset income")
    func capitalGains() {
        let gains = TaxEstimate.estimate(
            income: [], deductions: [],
            shortTermGains: 1_000, longTermGains: 10_000, settings: settings)
        // 10,000 × (1 − 0.5) + 1,000 = 6,000.
        #expect(gains.netCapitalGains == 6_000)
        #expect(gains.taxableIncome == 6_000)

        let losses = TaxEstimate.estimate(
            income: [.init(id: .random(), name: "Salary", amount: 50_000)],
            deductions: [], shortTermGains: -8_000, settings: settings)
        #expect(losses.netCapitalGains == 0)
        #expect(losses.taxableIncome == 50_000)
    }
}

@Suite("Lifetime projection")
struct LifetimeProjectionTests {

    private let tax = TaxEstimate.Settings.australian(financialYearEnding: 2027)

    @Test("A saver's net worth grows while working and funds retirement")
    func saverProjection() {
        let assumptions = LifetimeProjection.Assumptions(
            birthYear: 1980, retirementAge: 65, lifeExpectancy: 90,
            annualIncome: 120_000, annualExpenses: 60_000,
            retirementContribution: 12_000, pensionIncome: 0)
        let start = LifetimeProjection.Buckets(cash: 50_000, investments: 200_000,
                                               retirement: 300_000)
        let result = LifetimeProjection.project(start: start, assumptions: assumptions,
                                                currentYear: 2026, taxSettings: tax)
        #expect(!result.points.isEmpty)
        #expect(result.points.first?.age == 46)
        #expect(result.points.last?.age == 90)
        // Working years accumulate: net worth at retirement far exceeds today's.
        let atRetirement = result.points.first { $0.age == 65 }!
        #expect(atRetirement.netWorth > 550_000)
        // Retirement contributions landed in the retirement bucket.
        #expect(atRetirement.retirement > 300_000)
        // Money lasts the distance for this comfortable profile.
        #expect(result.lastsTheDistance)
    }

    @Test("An overspender depletes, and the depletion age is reported")
    func depletion() {
        let assumptions = LifetimeProjection.Assumptions(
            birthYear: 1960, retirementAge: 66, lifeExpectancy: 95,
            annualIncome: 0, annualExpenses: 90_000, pensionIncome: 10_000,
            returnCash: 0, returnInvestments: 0, returnRetirement: 0)
        let start = LifetimeProjection.Buckets(cash: 100_000, investments: 100_000,
                                               retirement: 200_000)
        let result = LifetimeProjection.project(start: start, assumptions: assumptions,
                                                currentYear: 2026, taxSettings: tax)
        // ~400k at ~80k+/yr net drawdown → runs out well before 95.
        let depletion = try! #require(result.depletionAge)
        #expect(depletion > 66 && depletion < 80)
        #expect(!result.lastsTheDistance)
    }

    @Test("Life events land on cash in their year")
    func lifeEvents() {
        let inheritance = LifetimeProjection.LifeEvent(name: "Inheritance", year: 2030,
                                                       amount: 250_000)
        let assumptions = LifetimeProjection.Assumptions(
            birthYear: 1980, retirementAge: 65, lifeExpectancy: 85,
            annualIncome: 80_000, annualExpenses: 80_000, inflation: 0,
            returnCash: 0, returnInvestments: 0, returnRetirement: 0,
            events: [inheritance])
        let start = LifetimeProjection.Buckets(cash: 10_000)
        let result = LifetimeProjection.project(start: start, assumptions: assumptions,
                                                currentYear: 2026, taxSettings: tax)
        let before = result.points.first { $0.year == 2029 }!
        let after = result.points.first { $0.year == 2030 }!
        #expect(after.notes == ["Inheritance"])
        #expect(after.netWorth - before.netWorth > 200_000)
    }

    @Test("Debts amortise with the level repayment and repayment counts as spending")
    func debts() {
        let assumptions = LifetimeProjection.Assumptions(
            birthYear: 1990, retirementAge: 65, lifeExpectancy: 70,
            annualIncome: 100_000, annualExpenses: 40_000, inflation: 0,
            returnCash: 0, returnInvestments: 0, returnRetirement: 0,
            debtInterest: Decimal(string: "0.05")!, debtRepayment: 40_000)
        let start = LifetimeProjection.Buckets(cash: 20_000, debts: 300_000)
        let result = LifetimeProjection.project(start: start, assumptions: assumptions,
                                                currentYear: 2026, taxSettings: tax)
        // 300k at 5% with 40k/yr amortises in ~9 years.
        let cleared = result.points.first { $0.debts == 0 }
        #expect(cleared != nil)
        #expect(cleared!.age < 2026 - 1990 + 12)
        // While owing, spending includes the repayment.
        #expect(result.points.first!.spending == 80_000)
    }
}

@Suite("Wellbeing score")
struct WellbeingScoreTests {

    @Test("A strong position scores full marks; a weak one scores low")
    func extremes() {
        let strong = WellbeingScore.compute(.init(
            income3Months: 30_000, spending3Months: 21_000, priorSpending3Months: 22_000,
            liquidBalance: 60_000, monthlySpend: 7_000,
            nonMortgageDebt: 0, annualIncome: 120_000))
        #expect(strong.total == 100)   // 30% savings, 8.6-month buffer, no debt, falling spend

        let weak = WellbeingScore.compute(.init(
            income3Months: 30_000, spending3Months: 33_000, priorSpending3Months: 24_000,
            liquidBalance: 0, monthlySpend: 11_000,
            nonMortgageDebt: 90_000, annualIncome: 120_000))
        #expect(weak.total == 0)       // dissaving, no buffer, 75% debt, spend up 37%
    }

    @Test("Components scale linearly and expose their inputs")
    func scaling() {
        let mid = WellbeingScore.compute(.init(
            income3Months: 30_000, spending3Months: 27_000, priorSpending3Months: 27_000,
            liquidBalance: 21_000, monthlySpend: 7_000,
            nonMortgageDebt: 36_000, annualIncome: 120_000))
        let byKind = Dictionary(uniqueKeysWithValues: mid.components.map { ($0.component, $0) })
        // 10% savings rate → half of 25.
        #expect(byKind[.savingsRate]!.points == Decimal(string: "12.5"))
        // 3-month buffer → half.
        #expect(byKind[.cashBuffer]!.points == Decimal(string: "12.5"))
        // 30% debt ratio → half of the inverted scale.
        #expect(byKind[.debtPressure]!.points == Decimal(string: "12.5"))
        // Flat spending → full marks.
        #expect(byKind[.spendingTrend]!.points == 25)
        #expect(mid.total == 62)
    }
}

@Suite("Spending insights")
struct SpendingInsightsTests {

    @Test("Two periods compare category by category with a grounded summary")
    func comparison() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let groceries = book.addAccount(Account(name: "Groceries", type: .expense, commodity: .aud))
        let dining = book.addAccount(Account(name: "Dining", type: .expense, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))

        func spend(_ amount: Decimal, to category: Account, on date: Date) {
            let txn = Transaction(currency: .aud, datePosted: date, description: "spend")
            txn.addSplit(account: category, value: amount)
            txn.addSplit(account: bank, value: -amount)
            book.addTransaction(txn)
        }
        func earn(_ amount: Decimal, on date: Date) {
            let txn = Transaction(currency: .aud, datePosted: date, description: "pay")
            txn.addSplit(account: salary, value: -amount)
            txn.addSplit(account: bank, value: amount)
            book.addTransaction(txn)
        }

        // Prior month: groceries 400, dining 300, income 5000.
        spend(400, to: groceries, on: day(2026, 5, 10))
        spend(300, to: dining, on: day(2026, 5, 15))
        earn(5_000, on: day(2026, 5, 1))
        // Current month: groceries 600, no dining, income 5000.
        spend(600, to: groceries, on: day(2026, 6, 10))
        earn(5_000, on: day(2026, 6, 1))

        let insights = FinancialReports.spendingInsights(
            book, from: day(2026, 6, 1), to: day(2026, 6, 30),
            priorFrom: day(2026, 5, 1), priorTo: day(2026, 5, 31),
            currency: .aud)

        #expect(insights.totalSpendingCurrent == 600)
        #expect(insights.totalSpendingPrior == 700)
        let groceriesLine = insights.expenses.first { $0.name == "Groceries" }!
        #expect(groceriesLine.delta == 200)
        let diningLine = insights.expenses.first { $0.name == "Dining" }!
        #expect(diningLine.isGone)

        let summary = insights.summary { "$\($0)" }
        #expect(!summary.isEmpty)
        // The headline reads the right direction with the right figure.
        #expect(summary.first!.contains("fell") && summary.first!.contains("$100"))
    }
}
