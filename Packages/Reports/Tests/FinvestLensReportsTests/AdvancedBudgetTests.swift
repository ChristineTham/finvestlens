//
//  AdvancedBudgetTests.swift
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

@Suite("Advanced budgets")
struct AdvancedBudgetTests {

    @Test("Rollover carries prior-period remainder into the effective budget")
    func rollover() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        // Prior month (Jan): budget 300, spent 200 → 100 unspent.
        let jan = Transaction(currency: .aud, datePosted: day(2026, 1, 10), description: "Food")
        jan.addSplit(account: food, value: dec("200")); jan.addSplit(account: bank, value: dec("-200"))
        book.addTransaction(jan)
        // Current month (Feb): spent 250.
        let feb = Transaction(currency: .aud, datePosted: day(2026, 2, 10), description: "Food")
        feb.addSplit(account: food, value: dec("250")); feb.addSplit(account: bank, value: dec("-250"))
        book.addTransaction(feb)

        var budget = Budget(name: "Monthly")
        budget.setAmount(dec("300"), for: food.guid)
        budget.setRollover(true, for: food.guid)

        let actuals = FinancialReports.budgetActuals(
            book, budget: budget, from: day(2026, 2, 1), to: day(2026, 2, 28), currency: .aud)
        let line = actuals.first!
        #expect(line.carryover == dec("100"))          // 300 − 200 prior
        #expect(line.effectiveBudget == dec("400"))     // 300 + 100
        #expect(line.remaining == dec("150"))           // 400 − 250
    }

    @Test("Zero-based summary reports unallocated income")
    func zeroBased() {
        let book = Book(baseCurrency: .aud)
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        var budget = Budget(name: "Monthly")
        budget.setAmount(dec("5000"), for: salary.guid)
        budget.setAmount(dec("600"), for: food.guid)
        budget.setAmount(dec("2000"), for: rent.guid)

        let summary = FinancialReports.budgetSummary(book, budget: budget, currency: .aud)
        #expect(summary.incomeBudget == dec("5000"))
        #expect(summary.expenseBudget == dec("2600"))
        #expect(summary.unallocated == dec("2400"))
    }
}
