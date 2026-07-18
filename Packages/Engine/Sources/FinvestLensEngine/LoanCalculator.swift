//
//  LoanCalculator.swift
//  FinvestLens — Engine
//
//  A loan / amortisation calculator (GnuCash's Tools ▸ Loan Repayment
//  Calculator). Pure arithmetic over `Decimal` — it never touches a book.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A fixed-rate amortising loan and the figures derived from it.
///
/// The periodic interest rate is the annual rate divided by the number of
/// payments per year, matching how a standard amortisation schedule (and
/// GnuCash's calculator) treats a nominal annual rate.
public struct LoanCalculator: Sendable, Equatable {

    /// Amount borrowed.
    public var principal: Decimal
    /// Nominal annual interest rate, as a percentage (e.g. `6.5` for 6.5%).
    public var annualRatePercent: Decimal
    /// Loan term in years.
    public var years: Double
    /// Payments per year (12 = monthly, 26 = fortnightly, 52 = weekly).
    public var paymentsPerYear: Int

    public init(principal: Decimal, annualRatePercent: Decimal,
                years: Double, paymentsPerYear: Int = 12) {
        self.principal = principal
        self.annualRatePercent = annualRatePercent
        self.years = years
        self.paymentsPerYear = max(1, paymentsPerYear)
    }

    /// Total number of payments over the term.
    public var numberOfPayments: Int {
        max(0, Int((years * Double(paymentsPerYear)).rounded()))
    }

    /// The interest rate applied each period, as a fraction.
    public var periodicRate: Double {
        (annualRatePercent as NSDecimalNumber).doubleValue / 100.0 / Double(paymentsPerYear)
    }

    /// The level payment that amortises the loan to zero over the term.
    ///
    /// `P · i / (1 − (1 + i)⁻ⁿ)`, or `P / n` when the rate is zero.
    public var payment: Decimal {
        let n = numberOfPayments
        guard n > 0 else { return 0 }
        let p = (principal as NSDecimalNumber).doubleValue
        let i = periodicRate
        let raw: Double
        if i == 0 {
            raw = p / Double(n)
        } else {
            raw = p * i / (1 - pow(1 + i, -Double(n)))
        }
        return Decimal(raw).rounded(2)
    }

    /// Total of all payments over the term. Summed from the schedule, whose
    /// final instalment is adjusted for rounding — so it agrees with the
    /// schedule to the cent rather than being `payment × n`, which the adjusted
    /// last payment makes slightly wrong.
    public var totalPaid: Decimal {
        schedule().reduce(Decimal(0)) { $0 + $1.payment }
    }

    /// Interest paid over the life of the loan (total paid − principal).
    public var totalInterest: Decimal {
        totalPaid - principal
    }

    /// One line of the amortisation schedule.
    public struct Period: Sendable, Equatable, Identifiable {
        public var id: Int { number }
        public let number: Int
        public let payment: Decimal
        public let interest: Decimal
        public let principal: Decimal
        public let balance: Decimal
    }

    /// The full amortisation schedule. The final payment absorbs rounding so the
    /// balance lands exactly on zero, as a real loan's last instalment does.
    public func schedule() -> [Period] {
        let n = numberOfPayments
        guard n > 0 else { return [] }
        let i = periodicRate
        let pay = payment
        var balance = principal
        var rows: [Period] = []
        rows.reserveCapacity(n)
        for period in 1...n {
            let interest = (Decimal(i) * balance).rounded(2)
            var principalPart = pay - interest
            var thisPayment = pay
            if period == n {
                // Clear whatever is left, interest included.
                principalPart = balance
                thisPayment = balance + interest
            }
            balance -= principalPart
            rows.append(Period(number: period, payment: thisPayment,
                               interest: interest, principal: principalPart,
                               balance: max(0, balance)))
        }
        return rows
    }

    /// Builds a scheduled loan-payment transaction (GnuCash's Mortgage/Loan
    /// assistant, `FR-SCH-04`): the fixed ``payment`` leaves `fromAccount`, split
    /// into a variable **interest** amount (`interestAccount`) and the remaining
    /// **principal** (`principalAccount`, formula `payment − interest`). Because
    /// the interest/principal split changes every period, the interest is a
    /// formula variable the user enters at post time (`FR-SCH-02`) — read it
    /// from ``schedule()``.
    public func scheduledPayment(name: String, currency: Commodity, startDate: Date,
                                 from fromAccount: GncGUID, principal principalAccount: GncGUID,
                                 interest interestAccount: GncGUID) -> ScheduledTransaction {
        let pay = currency.round(payment)
        let (period, interval): (RecurrencePeriod, Int)
        switch paymentsPerYear {
        case 1:  (period, interval) = (.yearly, 1)
        case 2:  (period, interval) = (.monthly, 6)
        case 4:  (period, interval) = (.monthly, 3)
        case 12: (period, interval) = (.monthly, 1)
        case 26: (period, interval) = (.weekly, 2)
        case 52: (period, interval) = (.weekly, 1)
        default: (period, interval) = (.monthly, 1)
        }
        return ScheduledTransaction(
            name: name, currency: currency, description: name,
            recurrence: Recurrence(period: period, interval: interval, startDate: startDate),
            splits: [
                ScheduledSplit(accountGUID: fromAccount, value: -pay, memo: "Payment"),
                ScheduledSplit(accountGUID: interestAccount, value: 0, memo: "Interest", formula: "interest"),
                ScheduledSplit(accountGUID: principalAccount, value: 0, memo: "Principal",
                               formula: "\(pay) - interest"),
            ])
    }
}

private extension Decimal {
    /// Rounds to `places` decimal places, banker's-free (plain half-up).
    func rounded(_ places: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, places, .plain)
        return result
    }
}
