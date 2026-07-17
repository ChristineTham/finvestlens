//
//  LoanCalculatorTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Loan calculator")
struct LoanCalculatorTests {

    @Test("Monthly payment matches the standard amortisation formula")
    func monthlyPayment() {
        // $300,000 at 6% over 30 years, monthly → the textbook $1,798.65.
        let loan = LoanCalculator(principal: 300_000, annualRatePercent: 6, years: 30)
        #expect(loan.numberOfPayments == 360)
        #expect(loan.payment == dec("1798.65"))
    }

    @Test("A zero-rate loan is just principal spread evenly")
    func zeroRate() {
        let loan = LoanCalculator(principal: 12_000, annualRatePercent: 0, years: 1)
        #expect(loan.payment == dec("1000"))
        #expect(loan.totalInterest == 0)
    }

    @Test("The schedule amortises to exactly zero")
    func scheduleClearsToZero() {
        let loan = LoanCalculator(principal: 10_000, annualRatePercent: 5, years: 2)
        let schedule = loan.schedule()
        #expect(schedule.count == 24)
        #expect(schedule.last?.balance == 0)
        // Principal repaid over the schedule equals the amount borrowed.
        let principalRepaid = schedule.reduce(Decimal(0)) { $0 + $1.principal }
        #expect(principalRepaid == dec("10000"))
        // Interest in the schedule agrees with the summary total.
        let interest = schedule.reduce(Decimal(0)) { $0 + $1.interest }
        #expect(interest == loan.totalInterest)
    }

    @Test("Fortnightly and weekly cadences scale the period count")
    func cadences() {
        let fortnightly = LoanCalculator(principal: 1_000, annualRatePercent: 10,
                                         years: 1, paymentsPerYear: 26)
        #expect(fortnightly.numberOfPayments == 26)
        let weekly = LoanCalculator(principal: 1_000, annualRatePercent: 10,
                                    years: 1, paymentsPerYear: 52)
        #expect(weekly.numberOfPayments == 52)
        // More frequent compounding on the same loan → slightly less total interest.
        #expect(weekly.totalInterest < fortnightly.totalInterest)
    }
}
