//
//  AlertsTests.swift
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
private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }

@Suite("Alerts engine")
struct AlertsTests {

    @Test("Overdue bill produces a critical alert")
    func billAlert() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        let sx = ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: day(2026, 1, 1)),
            splits: [ScheduledSplit(accountGUID: rent.guid, value: dec("800")),
                     ScheduledSplit(accountGUID: bank.guid, value: dec("-800"))])

        let alerts = FinancialReports.alerts(book, scheduled: [sx], currency: .aud, asOf: day(2026, 2, 5))
        let overdue = alerts.first { $0.kind == .billDue }
        #expect(overdue?.severity == .critical)
        #expect(overdue?.title.contains("Rent") == true)
    }

    @Test("Over-budget spending produces a warning")
    func budgetAlert() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        let t = Transaction(currency: .aud, datePosted: day(2026, 2, 10), description: "Groceries")
        t.addSplit(account: food, value: dec("500")); t.addSplit(account: bank, value: dec("-500"))
        book.addTransaction(t)
        var budget = Budget(name: "Monthly"); budget.setAmount(dec("300"), for: food.guid)

        let alerts = FinancialReports.alerts(book, budgets: [budget], currency: .aud, asOf: day(2026, 2, 20))
        #expect(alerts.contains { $0.kind == .overBudget && $0.severity == .warning })
    }

    @Test("Price target hit produces an info alert")
    func priceAlert() {
        let book = Book(baseCurrency: .aud)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA", fullName: "CBA", smallestFraction: 10000)
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 2, 1), value: dec("110")))
        let target = PriceTarget(commodity: cba, target: dec("100"), direction: .atOrAbove)

        let alerts = FinancialReports.alerts(book, currency: .aud, asOf: day(2026, 2, 2), priceTargets: [target])
        #expect(alerts.contains { $0.kind == .priceTarget })
        // Below-target direction not hit.
        let below = PriceTarget(commodity: cba, target: dec("100"), direction: .atOrBelow)
        let none = FinancialReports.alerts(book, currency: .aud, asOf: day(2026, 2, 2), priceTargets: [below])
        #expect(none.contains { $0.kind == .priceTarget } == false)
    }

    @Test("Projected negative balance is critical")
    func lowBalanceAlert() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        // Small opening balance.
        let open = Transaction(currency: .aud, datePosted: day(2026, 1, 1), description: "Open")
        open.addSplit(account: bank, value: dec("100"))
        open.addSplit(account: book.rootAccount, value: dec("-100"))
        book.addTransaction(open)
        // Big monthly rent will drive it negative.
        let sx = ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: day(2026, 2, 1)),
            splits: [ScheduledSplit(accountGUID: rent.guid, value: dec("800")),
                     ScheduledSplit(accountGUID: bank.guid, value: dec("-800"))])

        let alerts = FinancialReports.alerts(book, scheduled: [sx], currency: .aud,
                                             asOf: day(2026, 1, 15), forecastAccountID: bank.guid)
        let low = alerts.first { $0.kind == .lowBalance }
        #expect(low?.severity == .critical)
    }
}
