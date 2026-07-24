//
//  DebtPlanTests.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

@Suite("Debt Reduction Planner")
struct DebtPlanTests {

    private func debt(_ name: String, _ balance: Decimal, apr: Decimal,
                      minimum: Decimal) -> DebtPlan.Debt {
        DebtPlan.Debt(id: .random(), name: name, balance: balance,
                      apr: apr, minimumPayment: minimum)
    }

    @Test("A zero-interest debt amortises in exactly balance ÷ payment months")
    func zeroInterest() {
        let result = DebtPlan.simulate(debts: [debt("Car", 1200, apr: 0, minimum: 100)],
                                       budget: 100, strategy: .minimumsOnly, currency: .aud)
        #expect(result.months == 12)
        #expect(result.totalInterest == 0)
        #expect(result.paysOff)
        #expect(result.balanceSeries.count == 12)
        #expect(result.balanceSeries.last == 0)
        // Balance falls by exactly the payment each month.
        #expect(result.balanceSeries.first == 1100)
    }

    @Test("Avalanche beats snowball on interest; both beat minimums-only")
    func strategies() {
        // Snowball attacks the small 5% debt first; avalanche the big 20% one.
        let debts = [
            debt("Small low-rate", 500, apr: Decimal(string: "0.05")!, minimum: 25),
            debt("Big high-rate", 2000, apr: Decimal(string: "0.20")!, minimum: 50),
        ]
        let avalanche = DebtPlan.simulate(debts: debts, budget: 300,
                                          strategy: .avalanche, currency: .aud)
        let snowball = DebtPlan.simulate(debts: debts, budget: 300,
                                         strategy: .snowball, currency: .aud)
        let minimums = DebtPlan.simulate(debts: debts, budget: 0,
                                         strategy: .minimumsOnly, currency: .aud)

        #expect(avalanche.paysOff && snowball.paysOff)
        #expect(avalanche.totalInterest < snowball.totalInterest)
        #expect(snowball.totalInterest < minimums.totalInterest)
        #expect(avalanche.months <= snowball.months)
        #expect(snowball.months < minimums.months)

        // The focus order differs: avalanche retires the high-rate debt first,
        // snowball the small one.
        let avalancheBig = avalanche.debts.first { $0.name.hasPrefix("Big") }!
        let snowballSmall = snowball.debts.first { $0.name.hasPrefix("Small") }!
        #expect(avalancheBig.payoffMonth < avalanche.debts.first { $0.name.hasPrefix("Small") }!.payoffMonth)
        #expect(snowballSmall.payoffMonth < snowball.debts.first { $0.name.hasPrefix("Big") }!.payoffMonth)
    }

    @Test("A closed debt's payment rolls into the next (the snowball effect)")
    func rollingPayments() {
        let debts = [
            debt("First", 300, apr: 0, minimum: 100),
            debt("Second", 1200, apr: 0, minimum: 100),
        ]
        // Budget 300: months 1-2 pay First 200/mo (min 100 + extra 100)… First
        // closes in month 2, then Second gets the whole 300.
        let result = DebtPlan.simulate(debts: debts, budget: 300,
                                       strategy: .snowball, currency: .aud)
        // Total 1500 at 300/month → exactly 5 months, no interest.
        #expect(result.months == 5)
        #expect(result.totalInterest == 0)
    }

    @Test("A minimum that can't cover interest is flagged, not simulated forever")
    func underwater() {
        // 2%/month interest = $20 on $1,000; a $15 minimum never amortises.
        let stuck = debt("Stuck", 1000, apr: Decimal(string: "0.24")!, minimum: 15)
        let minimums = DebtPlan.simulate(debts: [stuck], budget: 0,
                                         strategy: .minimumsOnly, currency: .aud)
        #expect(!minimums.paysOff)
        #expect(minimums.underwater.count == 1)

        // Extra budget rescues it under a real strategy.
        let rescued = DebtPlan.simulate(debts: [stuck], budget: 200,
                                        strategy: .avalanche, currency: .aud)
        #expect(rescued.paysOff)
        #expect(rescued.underwater.isEmpty)
    }
}
