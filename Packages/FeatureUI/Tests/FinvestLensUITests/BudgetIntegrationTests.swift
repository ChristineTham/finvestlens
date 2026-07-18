//
//  BudgetIntegrationTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Budget integration")
struct BudgetIntegrationTests {

    @Test("Budget-vs-actual reflects this month's spending and persists")
    func budgetActualsAndPersist() async throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))

        // Spend $300 on groceries today.
        model.addTransfer(from: bank, to: groceries, amount: Decimal(300),
                          date: Date(), description: "Woolworths")

        var budget = Budget(name: "Monthly")
        budget.setAmount(Decimal(400), for: groceries)
        model.addBudget(budget)

        let actuals = model.budgetActuals(budget)
        let line = try #require(actuals.first { $0.accountName == "Groceries" })
        #expect(line.budgeted == Decimal(400))
        #expect(line.actual == Decimal(300))
        #expect(line.remaining == Decimal(100))
        #expect(!line.isOverBudget)

        try model.save()
        model.close()

        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.budgets.first?.name == "Monthly")
        #expect(reopened.budgets.first?.amount(for: groceries) == Decimal(400))
    }

    @Test("A savings goal is added, funded, and survives save/reload (FR-GOAL-01)")
    func savingsGoalPersists() async throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Savings", type: .bank))

        model.addSavingsGoal(SavingsGoal(name: "Holiday", accountGUID: bank,
                                         targetAmount: Decimal(2000)))
        let id = try #require(model.savingsGoals.first?.id)
        model.adjustSavingsGoal(id, by: Decimal(500))
        // Withdrawing more than is set aside floors at zero, never negative.
        model.adjustSavingsGoal(id, by: Decimal(-900))
        #expect(model.savingsGoals.first?.savedAmount == 0)
        model.adjustSavingsGoal(id, by: Decimal(750))
        #expect(model.savingsGoals.first?.savedAmount == Decimal(750))

        try model.save()
        model.close()

        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        let goal = try #require(reopened.savingsGoals.first)
        #expect(goal.name == "Holiday")
        #expect(goal.accountGUID == bank)
        #expect(goal.targetAmount == Decimal(2000))
        #expect(goal.savedAmount == Decimal(750))
        #expect(goal.remaining == Decimal(1250))
    }
}
