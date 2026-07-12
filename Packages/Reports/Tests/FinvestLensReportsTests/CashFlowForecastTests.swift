//
//  CashFlowForecastTests.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Cash-flow forecast")
struct CashFlowForecastTests {

    @Test("Projects the balance forward from scheduled transactions")
    func forecast() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))

        // Opening balance: $1,000 in the bank on Jan 1.
        let opening = Transaction(currency: .aud, datePosted: day(2026, 1, 1), description: "Opening")
        opening.addSplit(account: bank, value: dec("1000"))
        opening.addSplit(account: salary, value: dec("-1000"))
        book.addTransaction(opening)

        // Monthly rent of $800 starting Jan 15.
        let rentSX = ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: day(2026, 1, 15)),
            splits: [
                ScheduledSplit(accountGUID: rent.guid, value: dec("800")),
                ScheduledSplit(accountGUID: bank.guid, value: dec("-800")),
            ]
        )

        let points = FinancialReports.cashFlowForecast(
            book, accountID: bank.guid, scheduled: [rentSX],
            from: day(2026, 1, 2), horizon: day(2026, 3, 31), currency: .aud)

        // Start (1000), then Jan 15 (200), Feb 15 (-600), Mar 15 (-1400).
        #expect(points.count == 4)
        #expect(points[0].balance == dec("1000"))
        #expect(points[0].label == "Today")
        #expect(points[1].balance == dec("200"))       // 1000 − 800
        #expect(points[1].change == dec("-800"))
        #expect(points[2].balance == dec("-600"))
        #expect(points[3].balance == dec("-1400"))
    }

    @Test("Only occurrences that touch the account are projected")
    func unrelatedIgnored() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let savings = book.addAccount(Account(name: "Savings", type: .bank, commodity: .aud))
        let income = book.addAccount(Account(name: "Interest", type: .income, commodity: .aud))

        let savingsSX = ScheduledTransaction(
            name: "Interest", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: day(2026, 1, 15)),
            splits: [
                ScheduledSplit(accountGUID: savings.guid, value: dec("10")),
                ScheduledSplit(accountGUID: income.guid, value: dec("-10")),
            ]
        )

        let points = FinancialReports.cashFlowForecast(
            book, accountID: bank.guid, scheduled: [savingsSX],
            from: day(2026, 1, 1), horizon: day(2026, 6, 1), currency: .aud)
        #expect(points.count == 1)                     // only the starting point
        #expect(points[0].balance == 0)
    }

    @Test("What-if events are layered into the forecast")
    func whatIf() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let equity = book.addAccount(Account(name: "Opening", type: .equity, commodity: .aud))
        let opening = Transaction(currency: .aud, datePosted: day(2026, 1, 1), description: "Opening")
        opening.addSplit(account: bank, value: dec("1000"))
        opening.addSplit(account: equity, value: dec("-1000"))
        book.addTransaction(opening)

        // A hypothetical −$300 outflow on Feb 1 and +$500 inflow on Mar 1.
        let points = FinancialReports.cashFlowForecast(
            book, accountID: bank.guid, scheduled: [],
            from: day(2026, 1, 2), horizon: day(2026, 4, 1), currency: .aud,
            whatIf: [
                WhatIfEvent(date: day(2026, 2, 1), amount: dec("-300"), label: "Car repair"),
                WhatIfEvent(date: day(2026, 3, 1), amount: dec("500"), label: "Bonus"),
            ])
        #expect(points.count == 3)                     // start + two what-ifs
        #expect(points[1].balance == dec("700"))       // 1000 − 300
        #expect(points[1].isWhatIf)
        #expect(points[2].balance == dec("1200"))      // 700 + 500
        #expect(points[2].label == "Bonus")
    }
}
