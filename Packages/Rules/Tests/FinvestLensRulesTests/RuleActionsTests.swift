//
//  RuleActionsTests.swift
//  FinvestLens — Rules
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
import FinvestLensEngine
@testable import FinvestLensRules

struct RuleActionsTests {

    @Test("account trigger + setTags / setDescription actions (FR-RULE-01)")
    func newTriggersAndActions() {
        let rule = Rule(
            name: "Groceries",
            triggers: [
                RuleTrigger(field: .account, op: .contains, value: "Groceries"),
                RuleTrigger(field: .description, op: .contains, value: "woolworths"),
            ],
            matchAll: true,
            actions: [.setTags(["food", "essential"]), .setDescription("Woolworths")]
        )
        let group = RuleGroup(name: "G", rules: [rule])

        let hit = RuleEngine.evaluate([group], context: RuleContext(
            description: "WOOLWORTHS 1234", accountNames: ["Bank", "Groceries"]))
        #expect(hit.tags == ["food", "essential"])
        #expect(hit.descriptionText == "Woolworths")

        // The account trigger must actually gate the match.
        let miss = RuleEngine.evaluate([group], context: RuleContext(
            description: "WOOLWORTHS 1234", accountNames: ["Bank", "Rent"]))
        #expect(miss.tags.isEmpty)
        #expect(miss.descriptionText == nil)
    }

    @Test("setTags accumulates without duplicates across rules")
    func tagsAccumulate() {
        let g = RuleGroup(name: "G", rules: [
            Rule(name: "a", triggers: [RuleTrigger(field: .description, op: .contains, value: "x")],
                 actions: [.setTags(["one"])]),
            Rule(name: "b", triggers: [RuleTrigger(field: .description, op: .contains, value: "x")],
                 actions: [.setTags(["one", "two"])]),
        ])
        let outcome = RuleEngine.evaluate([g], context: RuleContext(description: "x"))
        #expect(outcome.tags == ["one", "two"])
    }
}
