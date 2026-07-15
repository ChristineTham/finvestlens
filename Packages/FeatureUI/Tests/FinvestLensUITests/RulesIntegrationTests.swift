//
//  RulesIntegrationTests.swift
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

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Rules integration")
struct RulesIntegrationTests {

    @Test("A rule categorises an imported row without manual assignment")
    func categorisesOnImport() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let subs = try #require(model.addAccount(name: "Subscriptions", type: .expense))

        model.addRule(Rule(
            name: "Netflix → Subscriptions",
            triggers: [RuleTrigger(field: .description, op: .contains, value: "netflix")],
            actions: [.setAccount(subs)]
        ))

        let qif = "!Type:Bank\nD09/20/2020\nT-19.99\nPNetflix\n^"
        let staged = model.parseBankFile(Data(qif.utf8), format: .qif)
        let results = model.matchStaged(staged, intoAccountID: bank)

        #expect(results.first?.suggestedAccountID == subs)     // rule categorised it
        let imported = model.importMatched(results, intoAccountID: bank)  // no assignments
        #expect(imported == 1)

        model.selectedAccountID = subs
        #expect(model.registerRows.count == 1)
    }

    @Test("Rules persist across save and reopen")
    func rulesPersist() async throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)

        let subs = try #require(model.addAccount(name: "Subscriptions", type: .expense))
        model.addRule(Rule(name: "R",
                           triggers: [RuleTrigger(field: .description, op: .contains, value: "spotify")],
                           actions: [.setAccount(subs)]))
        #expect(model.ruleGroups.first?.rules.count == 1)
        try model.save()
        model.close()

        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.ruleGroups.first?.rules.first?.name == "R")
    }
}
