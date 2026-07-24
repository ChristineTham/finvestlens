//
//  GoalsModelTests.swift
//  FinvestLens — FeatureUI
//
//  Savings-goal model logic (AppModel+Goals): CRUD, the adjustment clamp,
//  earmark totals, and which accounts a goal may draw from (FR-GOAL-01).
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

@MainActor
@Suite("Savings goals model")
struct GoalsModelTests {

    @Test("Goal-eligible accounts are the asset-like ones (casing-safe)")
    func eligibility() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Everyday", type: .bank))
        _ = try #require(model.addAccount(name: "Wallet", type: .cash))
        _ = try #require(model.addAccount(name: "Rent", type: .expense))
        _ = try #require(model.addAccount(name: "Visa", type: .credit))

        // The regression this pins: typeName is capitalized ("Bank") while
        // AccountType.rawValue is lowercase — a direct comparison silently
        // emptied this list and disabled the Add Goal button.
        let eligible = model.goalEligibleAccounts
        #expect(eligible.count == 2)
        #expect(eligible.contains { $0.id == bank })
        #expect(!eligible.contains { $0.name == "Rent" })
        #expect(!eligible.contains { $0.name == "Visa" })
    }

    @Test("Goals add, edit, and delete as one persisted collection")
    func crud() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Savings", type: .bank))

        var goal = SavingsGoal(name: "Holiday", accountGUID: bank, targetAmount: dec("2000"))
        model.addSavingsGoal(goal)
        #expect(model.savingsGoals.count == 1)

        goal.name = "Japan Trip"
        goal.targetAmount = dec("3500")
        model.updateSavingsGoal(goal)
        #expect(model.savingsGoals.first?.name == "Japan Trip")
        #expect(model.savingsGoals.first?.targetAmount == dec("3500"))

        // Updating or deleting a goal that does not exist changes nothing.
        model.updateSavingsGoal(SavingsGoal(name: "Ghost", targetAmount: dec("1")))
        #expect(model.savingsGoals.count == 1)
        #expect(model.savingsGoals.first?.name == "Japan Trip")
        model.deleteSavingsGoal(GncGUID.random())
        #expect(model.savingsGoals.count == 1)

        model.deleteSavingsGoal(goal.id)
        #expect(model.savingsGoals.isEmpty)
    }

    @Test("Adjustments accumulate and clamp at zero, and ignore unknown goals")
    func adjustmentClamp() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Savings", type: .bank))

        let goal = SavingsGoal(name: "Holiday", accountGUID: bank, targetAmount: dec("1000"))
        model.addSavingsGoal(goal)

        model.adjustSavingsGoal(goal.id, by: dec("400"))
        model.adjustSavingsGoal(goal.id, by: dec("100.50"))
        #expect(model.savingsGoals.first?.savedAmount == dec("500.50"))

        // Withdrawing more than is set aside floors at zero.
        model.adjustSavingsGoal(goal.id, by: dec("-9999"))
        #expect(model.savingsGoals.first?.savedAmount == 0)

        // Exactly zero delta is a no-op in effect.
        model.adjustSavingsGoal(goal.id, by: dec("250"))
        model.adjustSavingsGoal(goal.id, by: 0)
        #expect(model.savingsGoals.first?.savedAmount == dec("250"))

        // Unknown goal: nothing changes anywhere.
        model.adjustSavingsGoal(GncGUID.random(), by: dec("50"))
        #expect(model.savingsGoals.first?.savedAmount == dec("250"))
    }

    @Test("Earmarked totals sum sibling goals on an account, excluding the one being edited")
    func earmarkedTotals() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let savings = try #require(model.addAccount(name: "Savings", type: .bank))
        let offset = try #require(model.addAccount(name: "Offset", type: .bank))

        let holiday = SavingsGoal(name: "Holiday", accountGUID: savings,
                                  targetAmount: dec("2000"), savedAmount: dec("500"))
        let car = SavingsGoal(name: "Car", accountGUID: savings,
                              targetAmount: dec("9000"), savedAmount: dec("200"))
        let roof = SavingsGoal(name: "Roof", accountGUID: offset,
                               targetAmount: dec("5000"), savedAmount: dec("50"))
        let unlinked = SavingsGoal(name: "Loose", targetAmount: dec("100"), savedAmount: dec("77"))
        for goal in [holiday, car, roof, unlinked] { model.addSavingsGoal(goal) }

        #expect(model.earmarkedTotal(forAccount: savings) == dec("700"))
        #expect(model.earmarkedTotal(forAccount: savings, excluding: car.id) == dec("500"))
        #expect(model.earmarkedTotal(forAccount: savings, excluding: holiday.id) == dec("200"))
        #expect(model.earmarkedTotal(forAccount: offset) == dec("50"))
        #expect(model.earmarkedTotal(forAccount: GncGUID.random()) == 0)

        #expect(model.savingsGoals(forAccount: savings).map(\.name).sorted() == ["Car", "Holiday"])
        #expect(model.savingsGoals(forAccount: offset).map(\.name) == ["Roof"])
    }
}
