//
//  BudgetReportTests.swift
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

@Suite("Budget vs actual")
struct BudgetReportTests {

    @Test("Compares budgeted amounts to actual spending")
    func budgetActuals() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let groceries = book.addAccount(Account(name: "Groceries", type: .expense, commodity: .aud))
        let dining = book.addAccount(Account(name: "Dining", type: .expense, commodity: .aud))

        // Spend $450 groceries and $120 dining in January.
        let shop = Transaction(currency: .aud, datePosted: day(2026, 1, 10), description: "Shop")
        shop.addSplit(account: groceries, value: dec("450"))
        shop.addSplit(account: bank, value: dec("-450"))
        book.addTransaction(shop)
        let meal = Transaction(currency: .aud, datePosted: day(2026, 1, 20), description: "Dinner")
        meal.addSplit(account: dining, value: dec("120"))
        meal.addSplit(account: bank, value: dec("-120"))
        book.addTransaction(meal)

        var budget = Budget(name: "Monthly")
        budget.setAmount(dec("400"), for: groceries.guid)   // over by 50
        budget.setAmount(dec("200"), for: dining.guid)      // under by 80

        let actuals = FinancialReports.budgetActuals(book, budget: budget,
                                                     from: day(2026, 1, 1), to: day(2026, 1, 31),
                                                     currency: .aud)
        let g = actuals.first { $0.accountName == "Groceries" }!
        #expect(g.budgeted == dec("400"))
        #expect(g.actual == dec("450"))
        #expect(g.remaining == dec("-50"))
        #expect(g.isOverBudget)

        let d = actuals.first { $0.accountName == "Dining" }!
        #expect(d.actual == dec("120"))
        #expect(d.remaining == dec("80"))
        #expect(!d.isOverBudget)
    }

    @Test("Budget round-trips through Codable")
    func codable() throws {
        var budget = Budget(name: "B")
        budget.setAmount(dec("100"), for: .random())
        let data = try JSONEncoder().encode(budget)
        let decoded = try JSONDecoder().decode(Budget.self, from: data)
        #expect(decoded == budget)
    }
}
