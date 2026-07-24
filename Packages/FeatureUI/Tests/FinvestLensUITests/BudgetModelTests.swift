//
//  BudgetModelTests.swift
//  FinvestLens — FeatureUI
//
//  Budget model logic (AppModel+Budget): actuals against posted transactions
//  (over and under), the month window, rollover carryover, the zero-based
//  summary, and auto-budget averaging.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

/// Fixed instants (UTC): the budget month window is computed in UTC.
private let feb15 = Date(timeIntervalSince1970: 1_771_113_600)   // 2026-02-15T00:00:00Z
private let mar15 = Date(timeIntervalSince1970: 1_773_532_800)   // 2026-03-15T00:00:00Z
private let apr02 = Date(timeIntervalSince1970: 1_775_088_000)   // 2026-04-02T00:00:00Z

@MainActor
@Suite("Budget model")
struct BudgetModelTests {

    @Test("Budgets update and delete by id; unknown ids change nothing")
    func crud() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))

        var budget = Budget(name: "Monthly")
        budget.setAmount(dec("400"), for: groceries)
        model.addBudget(budget)
        #expect(model.budgets.count == 1)

        budget.name = "Household"
        budget.setAmount(dec("450"), for: groceries)
        model.updateBudget(budget)
        #expect(model.budgets.first?.name == "Household")
        #expect(model.budgets.first?.amount(for: groceries) == dec("450"))

        model.updateBudget(Budget(name: "Ghost"))
        #expect(model.budgets.count == 1)
        #expect(model.budgets.first?.name == "Household")

        model.deleteBudget(GncGUID.random())
        #expect(model.budgets.count == 1)
        model.deleteBudget(budget.id)
        #expect(model.budgets.isEmpty)
    }

    @Test("Actuals tally only the calendar month asked for, over and under budget")
    func actualsWindowAndOverspend() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let dining = try #require(model.addAccount(name: "Dining", type: .expense))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))

        // March activity…
        model.addTransfer(from: bank, to: groceries, amount: dec("300"),
                          date: mar15, description: "Woolworths")
        model.addTransfer(from: bank, to: dining, amount: dec("180"),
                          date: mar15, description: "Restaurant")
        model.addTransfer(from: salary, to: bank, amount: dec("5000"),
                          date: mar15, description: "Pay")
        // …and an April purchase that must stay out of March's actuals.
        model.addTransfer(from: bank, to: groceries, amount: dec("999"),
                          date: apr02, description: "Costco")

        var budget = Budget(name: "Monthly")
        budget.setAmount(dec("400"), for: groceries)     // under budget
        budget.setAmount(dec("100"), for: dining)        // over budget
        budget.setAmount(dec("4500"), for: salary)       // income line
        model.addBudget(budget)

        let actuals = model.budgetActuals(budget, month: mar15)
        #expect(actuals.count == 3)

        let groceriesLine = try #require(actuals.first { $0.accountName == "Groceries" })
        #expect(groceriesLine.budgeted == dec("400"))
        #expect(groceriesLine.actual == dec("300"))      // April's 999 excluded
        #expect(groceriesLine.remaining == dec("100"))
        #expect(groceriesLine.carryover == 0)
        #expect(!groceriesLine.isOverBudget)
        #expect(groceriesLine.fractionUsed == 0.75)

        let diningLine = try #require(actuals.first { $0.accountName == "Dining" })
        #expect(diningLine.actual == dec("180"))
        #expect(diningLine.remaining == dec("-80"))
        #expect(diningLine.isOverBudget)

        // Income actuals are sign-adjusted so earnings read positive.
        let salaryLine = try #require(actuals.first { $0.accountName == "Salary" })
        #expect(salaryLine.actual == dec("5000"))
        #expect(salaryLine.remaining == dec("-500"))

        // A month with no postings: actuals are zero, nothing is over.
        let january = model.budgetActuals(budget, month: Date(timeIntervalSince1970: 1_767_225_600))
        #expect(january.allSatisfy { $0.actual == 0 && !$0.isOverBudget })

        // No book: no lines.
        let empty = AppModel()
        #expect(empty.budgetActuals(budget, month: mar15).isEmpty)
    }

    @Test("A rollover line carries last month's unspent remainder into this month")
    func rolloverCarryover() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        model.addTransfer(from: bank, to: groceries, amount: dec("300"),
                          date: feb15, description: "February shop")
        model.addTransfer(from: bank, to: groceries, amount: dec("250"),
                          date: mar15, description: "March shop")

        var budget = Budget(name: "Envelope")
        budget.setAmount(dec("400"), for: groceries)
        model.addBudget(budget)
        let id = try #require(model.budgets.first?.id)

        model.setBudgetRollover(true, for: groceries, in: id)
        #expect(model.budgets.first?.lines.first?.rollover == true)

        let line = try #require(model.budgetActuals(model.budgets[0], month: mar15).first)
        #expect(line.carryover == dec("100"))            // 400 budgeted − 300 spent in Feb
        #expect(line.effectiveBudget == dec("500"))
        #expect(line.actual == dec("250"))
        #expect(line.remaining == dec("250"))

        model.setBudgetRollover(false, for: groceries, in: id)
        #expect(model.budgets.first?.lines.first?.rollover == false)
        // Toggling a line that is not in the budget leaves it untouched.
        model.setBudgetRollover(true, for: bank, in: id)
        #expect(model.budgets.first?.lines.count == 1)
    }

    @Test("The zero-based summary balances income lines against expense lines")
    func summary() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let rent = try #require(model.addAccount(name: "Rent", type: .expense))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))

        var budget = Budget(name: "Plan")
        budget.setAmount(dec("600"), for: groceries)
        budget.setAmount(dec("2400"), for: rent)
        budget.setAmount(dec("5000"), for: salary)
        budget.setAmount(dec("123"), for: bank)          // neither income nor expense: ignored
        model.addBudget(budget)

        let summary = try #require(model.budgetSummary(budget))
        #expect(summary.incomeBudget == dec("5000"))
        #expect(summary.expenseBudget == dec("3000"))
        #expect(summary.unallocated == dec("2000"))

        #expect(AppModel().budgetSummary(budget) == nil)  // no book
    }

    @Test("Auto-budget sets each existing line to its average actual over complete months")
    func autoBudget() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let dining = try #require(model.addAccount(name: "Dining", type: .expense))

        // The windows auto-budget reads are the last N *complete* UTC months.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let thisMonthStart = try #require(calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())))
        func daysInto(monthsBack: Int, days: Double) -> Date {
            calendar.date(byAdding: .month, value: -monthsBack, to: thisMonthStart)!
                .addingTimeInterval(days * 86_400)
        }
        model.addTransfer(from: bank, to: groceries, amount: dec("300"),
                          date: daysInto(monthsBack: 1, days: 5), description: "Last month")
        model.addTransfer(from: bank, to: groceries, amount: dec("150"),
                          date: daysInto(monthsBack: 2, days: 5), description: "Two back")
        // Spending in the current month must not count: months are complete only.
        model.addTransfer(from: bank, to: groceries, amount: dec("888"),
                          date: thisMonthStart.addingTimeInterval(3_600), description: "This month")

        var budget = Budget(name: "Auto")
        budget.setAmount(dec("999"), for: groceries)
        model.addBudget(budget)
        let id = try #require(model.budgets.first?.id)

        // (300 + 150 + 0) / 3, to the cent.
        model.autoBudget(id, months: 3)
        #expect(model.budgets.first?.amount(for: groceries) == dec("150"))
        // Only existing lines are filled; no line is invented for Dining.
        #expect(model.budgets.first?.amount(for: dining) == nil)
        #expect(model.budgets.first?.lines.count == 1)

        // A shorter horizon changes the divisor: (300 + 150) / 2.
        model.autoBudget(id, months: 2)
        #expect(model.budgets.first?.amount(for: groceries) == dec("225"))

        // Degenerate inputs change nothing.
        model.autoBudget(id, months: 0)
        #expect(model.budgets.first?.amount(for: groceries) == dec("225"))
        model.autoBudget(GncGUID.random(), months: 3)
        #expect(model.budgets.first?.amount(for: groceries) == dec("225"))
    }
}
