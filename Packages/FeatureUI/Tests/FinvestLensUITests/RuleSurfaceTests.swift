//
//  RuleSurfaceTests.swift
//  FinvestLens — FeatureUI
//
//  The parts of the rules engine that had no way in.
//
//  `setNotes`, multi-trigger AND/OR, rule groups with ordering and isActive,
//  and `Book.allTags` were all implemented and tested, and none could be
//  reached: the Add Rule sheet hard-coded one trigger and `setAccount`, the
//  list flattened groups away with `flatMap(\.rules)`, and the Tags field was
//  free text.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensRules
@testable import FinvestLensUI

@MainActor
@Suite("Rule surface")
struct RuleSurfaceTests {

    private func makeModel() throws -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        return (model, url)
    }

    // MARK: Groups

    @Test("Groups can be made, renamed, switched off and deleted")
    func groupLifecycle() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let id = model.addRuleGroup(named: "Imports")
        #expect(model.ruleGroups.map(\.name).contains("Imports"))

        model.renameRuleGroup(id, to: "Bank Imports")
        #expect(model.ruleGroups.first { $0.id == id }?.name == "Bank Imports")

        model.setRuleGroupActive(id, false)
        #expect(model.ruleGroups.first { $0.id == id }?.isActive == false)

        model.deleteRuleGroup(id)
        #expect(!model.ruleGroups.contains { $0.id == id })
    }

    @Test("A rule can be added to a named group")
    func addToGroup() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let first = model.addRuleGroup(named: "First")
        let second = model.addRuleGroup(named: "Second")
        model.addRule(Rule(name: "r"), toGroup: second)
        #expect(model.ruleGroups.first { $0.id == first }?.rules.isEmpty == true)
        #expect(model.ruleGroups.first { $0.id == second }?.rules.count == 1)
    }

    /// Order is a setting, not decoration: rules run in order and
    /// `stopProcessing` cuts off the rest.
    @Test("Rules can be reordered within a group")
    func reorder() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let group = model.addRuleGroup(named: "G")
        model.addRule(Rule(name: "a"), toGroup: group)
        model.addRule(Rule(name: "b"), toGroup: group)
        model.addRule(Rule(name: "c"), toGroup: group)

        model.moveRules(inGroup: group, from: IndexSet(integer: 2), to: 0)
        #expect(model.ruleGroups.first { $0.id == group }?.rules.map(\.name) == ["c", "a", "b"])
    }

    @Test("A rule can be switched off without deleting it")
    func ruleActive() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let group = model.addRuleGroup(named: "G")
        let rule = Rule(name: "r")
        model.addRule(rule, toGroup: group)
        model.setRuleActive(rule.id, false)
        #expect(model.ruleGroups.first { $0.id == group }?.rules.first?.isActive == false)
    }

    // MARK: Editing

    /// The editor must hand back everything it was given, or saving an existing
    /// rule quietly drops the parts it never showed — the same shape as the
    /// transaction editor destroying reconcile state.
    @Test("Editing a rule preserves every field the engine honours")
    func editRoundTrip() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let account = try #require(model.addAccount(name: "Food", type: .expense))
        let group = model.addRuleGroup(named: "G")

        let original = Rule(
            name: "Groceries",
            triggers: [RuleTrigger(field: .description, op: .contains, value: "WOOLIES"),
                       RuleTrigger(field: .amount, op: .greaterThan, value: "10")],
            matchAll: false,
            actions: [.setAccount(account), .setNotes("weekly shop")],
            stopProcessing: true)
        model.addRule(original, toGroup: group)

        var edited = original
        edited.name = "Groceries (renamed)"
        model.updateRule(edited)

        let saved = try #require(model.ruleGroups.first { $0.id == group }?.rules.first)
        #expect(saved.name == "Groceries (renamed)")
        #expect(saved.triggers.count == 2)
        #expect(saved.matchAll == false)
        #expect(saved.stopProcessing)
        #expect(saved.actions.contains(.setNotes("weekly shop")))
        #expect(saved.actions.contains(.setAccount(account)))
    }

    /// A rule that sets notes and no account is legitimate, and the engine has
    /// always applied it — there was simply no way to make one.
    @Test("A notes-only rule reaches the engine and does what it says")
    func notesOnlyRule() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        _ = try model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "WOOLIES 123", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -10),
                     SplitInput(accountID: food, value: 10)])

        model.addRule(Rule(name: "note it",
                           triggers: [RuleTrigger(field: .description, op: .contains,
                                                  value: "WOOLIES")],
                           actions: [.setNotes("groceries")]))

        let proposals = model.previewHistoricalRules()
        #expect(proposals.count == 1)
        #expect(proposals.first?.proposedNotes == "groceries")
        model.applyHistoricalRules(proposals)
        #expect(model.book?.transactions.first?.notes == "groceries")
    }

    /// AND and OR must mean different things, or the picker is decoration.
    @Test("Match-all and match-any select different transactions")
    func andOrDiffer() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let triggers = [RuleTrigger(field: .description, op: .contains, value: "WOOLIES"),
                        RuleTrigger(field: .amount, op: .greaterThan, value: "100")]

        model.ruleGroups = [RuleGroup(name: "G", rules: [
            Rule(name: "all", triggers: triggers, matchAll: true, actions: [.setNotes("all")])
        ])]
        // Matches the description but not the amount.
        #expect(model.ruleOutcome(description: "WOOLIES 1", amount: 5).notes == nil)

        model.ruleGroups = [RuleGroup(name: "G", rules: [
            Rule(name: "any", triggers: triggers, matchAll: false, actions: [.setNotes("any")])
        ])]
        #expect(model.ruleOutcome(description: "WOOLIES 1", amount: 5).notes == "any")
    }

    /// The list writes each rule into one line; every part the engine honours
    /// has to appear, or two different rules read identically.
    @Test("The summary says everything the rule does")
    func summary() throws {
        let account = GncGUID.random()
        let rule = Rule(name: "r",
                        triggers: [RuleTrigger(field: .description, op: .contains, value: "A"),
                                   RuleTrigger(field: .memo, op: .equals, value: "B")],
                        matchAll: false,
                        actions: [.setAccount(account), .setNotes("n")],
                        stopProcessing: true)
        let text = RulesView.summary(rule) { _ in "Food" }
        #expect(text.contains(" or "))
        #expect(text.contains("→ Food"))
        #expect(text.contains("notes “n”"))
        #expect(text.contains("then stop"))
    }

    // MARK: Tags

    @Test("Known tags come from the book, and exclude ones already used")
    func tagSuggestions() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        _ = try model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "a", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -1), SplitInput(accountID: food, value: 1)],
            tags: ["groceries", "weekly", "grog"])

        #expect(model.knownTags == ["groceries", "grog", "weekly"])
        #expect(model.tagSuggestions(prefix: "gro") == ["groceries", "grog"])
        #expect(model.tagSuggestions(prefix: "gro", excluding: ["groceries"]) == ["grog"])
        #expect(model.tagSuggestions(prefix: "") == ["groceries", "grog", "weekly"])
        #expect(model.tagSuggestions(prefix: "zzz").isEmpty)
    }
}
