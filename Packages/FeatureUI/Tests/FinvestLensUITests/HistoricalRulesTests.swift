//
//  HistoricalRulesTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensRules
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Apply rules to history")
struct HistoricalRulesTests {

    @Test("Rule recategorises a matching historical transaction")
    func recategorise() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let uncategorised = try #require(model.addAccount(name: "Uncategorised", type: .expense))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))

        // A grocery purchase miscategorised to "Uncategorised".
        try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "WOOLWORTHS 123",
                                 currency: .aud, splits: [
            SplitInput(accountID: uncategorised, value: dec("50")),
            SplitInput(accountID: bank, value: dec("-50")),
        ])

        model.addRule(Rule(name: "Groceries",
                           triggers: [RuleTrigger(field: .description, op: .contains, value: "WOOLWORTHS")],
                           actions: [.setAccount(groceries), .setNotes("Auto: groceries")]))

        let preview = model.previewHistoricalRules()
        #expect(preview.count == 1)
        #expect(preview.first?.proposedCategory == "Groceries")
        #expect(preview.first?.proposedNotes == "Auto: groceries")

        model.applyHistoricalRules(preview)

        // The expense leg now points at Groceries; re-preview yields nothing new
        // for the category (already applied).
        model.selectedAccountID = groceries
        #expect(model.registerRows.contains { $0.description == "WOOLWORTHS 123" })
        // Uncategorised no longer has the posting.
        model.selectedAccountID = uncategorised
        #expect(model.registerRows.isEmpty)
    }

    @Test("No rules or no matches yields an empty preview")
    func noMatches() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "COLES",
                                 currency: .aud, splits: [
            SplitInput(accountID: food, value: dec("20")),
            SplitInput(accountID: bank, value: dec("-20")),
        ])
        model.addRule(Rule(name: "Fuel",
                           triggers: [RuleTrigger(field: .description, op: .contains, value: "SHELL")],
                           actions: [.setAccount(food)]))
        #expect(model.previewHistoricalRules().isEmpty)
    }
}
