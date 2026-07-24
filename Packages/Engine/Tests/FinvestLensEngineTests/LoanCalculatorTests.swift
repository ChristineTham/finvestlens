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

    @Test("The loan assistant builds a monthly payment SX with variable interest (FR-SCH-04)")
    func scheduledPayment() {
        let loan = LoanCalculator(principal: 300_000, annualRatePercent: 6, years: 30)
        let bank = GncGUID.random(), principal = GncGUID.random(), interest = GncGUID.random()
        let sx = loan.scheduledPayment(name: "Mortgage", currency: .aud,
                                       startDate: Date(timeIntervalSince1970: 0),
                                       from: bank, principal: principal, interest: interest)
        #expect(sx.recurrence.period == .monthly)
        #expect(sx.splits.count == 3)
        #expect(sx.variableNames == ["interest"])

        // Post the first instalment with that period's interest (from schedule()).
        let firstInterest = loan.schedule().first!.interest      // 1500.00 at 6%/12 on 300k
        let book = Book(baseCurrency: .aud)
        let bankA = Account(guid: bank, name: "Bank", type: .bank, commodity: .aud)
        let liab = Account(guid: principal, name: "Mortgage", type: .liability, commodity: .aud)
        let exp = Account(guid: interest, name: "Interest", type: .expense, commodity: .aud)
        book.addAccount(bankA); book.addAccount(liab); book.addAccount(exp)
        let txn = try! #require(ScheduledTransactionService.post(
            sx, date: Date(timeIntervalSince1970: 0), into: book,
            variables: ["interest": firstInterest]))
        #expect(txn.isBalanced)
        // Interest leg = the period interest; principal leg = payment − interest.
        #expect(txn.splits.first { $0.account?.guid == interest }?.value == firstInterest)
        #expect(txn.splits.first { $0.account?.guid == principal }?.value == loan.payment - firstInterest)
    }
}

@Suite("Loan calculator gaps")
struct LoanCalculatorGapTests {

    /// $1,200 at 12% over one year: i = 1%/month, n = 12.
    /// payment = 1200·0.01 / (1 − 1.01⁻¹²) = 106.6185… → 106.62.
    /// The figures below were amortised by hand with cent-rounded interest.
    @Test("Known-answer schedule, hand-amortised")
    func knownAnswerSchedule() {
        let loan = LoanCalculator(principal: 1_200, annualRatePercent: 12, years: 1)
        #expect(loan.numberOfPayments == 12)
        #expect(loan.payment == dec("106.62"))

        let schedule = loan.schedule()
        #expect(schedule.count == 12)

        // First period from first principles: interest = 1% of 1,200.
        #expect(schedule[0].interest == dec("12.00"))
        #expect(schedule[0].principal == dec("94.62"))
        #expect(schedule[0].balance == dec("1105.38"))
        #expect(schedule[0].number == 1)
        #expect(schedule[0].id == 1)

        // Every row: payment = interest + principal; balance falls by principal.
        var previous = loan.principal
        for row in schedule {
            #expect(row.payment == row.interest + row.principal, "period \(row.number)")
            #expect(row.balance == max(0, previous - row.principal), "period \(row.number)")
            previous = row.balance
        }

        // Final instalment absorbs rounding: 105.54 left plus 1.06 interest.
        let last = schedule[11]
        #expect(last.payment == dec("106.60"))
        #expect(last.interest == dec("1.06"))
        #expect(last.principal == dec("105.54"))
        #expect(last.balance == 0)

        // Totals agree with the hand-summed schedule, not payment × n.
        #expect(loan.totalPaid == dec("1279.42"))
        #expect(loan.totalInterest == dec("79.42"))
    }

    @Test("Fractional years, clamped cadence and a zero-length term")
    func termHandling() {
        // 1.5 years monthly → 18 payments.
        let loan = LoanCalculator(principal: 1_800, annualRatePercent: 0, years: 1.5)
        #expect(loan.numberOfPayments == 18)
        #expect(loan.payment == dec("100"))

        // paymentsPerYear is clamped to at least 1.
        let annual = LoanCalculator(principal: 1_000, annualRatePercent: 0,
                                    years: 2, paymentsPerYear: 0)
        #expect(annual.paymentsPerYear == 1)
        #expect(annual.numberOfPayments == 2)
        #expect(annual.payment == dec("500"))

        // A zero-length term produces no payments and an empty schedule.
        let degenerate = LoanCalculator(principal: 1_000, annualRatePercent: 5, years: 0)
        #expect(degenerate.numberOfPayments == 0)
        #expect(degenerate.payment == 0)
        #expect(degenerate.schedule().isEmpty)
        #expect(degenerate.totalPaid == 0)
    }

    @Test("Loan assistant maps every cadence onto a recurrence")
    func cadenceMapping() {
        let expected: [(Int, RecurrencePeriod, Int)] = [
            (1, .yearly, 1), (2, .monthly, 6), (4, .monthly, 3),
            (12, .monthly, 1), (26, .weekly, 2), (52, .weekly, 1),
            (13, .monthly, 1),          // anything else falls back to monthly
        ]
        for (perYear, period, interval) in expected {
            let loan = LoanCalculator(principal: 10_000, annualRatePercent: 5,
                                      years: 5, paymentsPerYear: perYear)
            let sx = loan.scheduledPayment(name: "Loan", currency: .aud,
                                           startDate: Date(timeIntervalSince1970: 0),
                                           from: .random(), principal: .random(),
                                           interest: .random())
            #expect(sx.recurrence.period == period, "\(perYear)/yr")
            #expect(sx.recurrence.interval == interval, "\(perYear)/yr")
        }
    }

    @Test("Loan assistant splits: fixed payment, variable interest, derived principal")
    func scheduledSplitShape() {
        let loan = LoanCalculator(principal: 1_200, annualRatePercent: 12, years: 1)
        let bank = GncGUID.random(), principal = GncGUID.random(), interest = GncGUID.random()
        let sx = loan.scheduledPayment(name: "Car loan", currency: .aud,
                                       startDate: Date(timeIntervalSince1970: 0),
                                       from: bank, principal: principal, interest: interest)
        #expect(sx.name == "Car loan")
        #expect(sx.transactionDescription == "Car loan")
        #expect(sx.splits.count == 3)

        let payment = sx.splits[0]
        #expect(payment.accountGUID == bank)
        #expect(payment.value == dec("-106.62"))
        #expect(payment.memo == "Payment")
        #expect(payment.formula == nil)

        let interestLeg = sx.splits[1]
        #expect(interestLeg.accountGUID == interest)
        #expect(interestLeg.memo == "Interest")
        #expect(interestLeg.formula == "interest")

        let principalLeg = sx.splits[2]
        #expect(principalLeg.accountGUID == principal)
        #expect(principalLeg.memo == "Principal")
        #expect(principalLeg.formula == "106.62 - interest")
    }
}
