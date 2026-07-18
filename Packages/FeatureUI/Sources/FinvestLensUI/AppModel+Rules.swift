//
//  AppModel+Rules.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensRules

@MainActor
extension AppModel {

    /// Adds a categorisation rule to `groupID`, or the first (or a new) group.
    public func addRule(_ rule: Rule, toGroup groupID: UUID? = nil) {
        if let groupID, let index = ruleGroups.firstIndex(where: { $0.id == groupID }) {
            ruleGroups[index].rules.append(rule)
        } else if ruleGroups.isEmpty {
            ruleGroups.append(RuleGroup(name: "Rules", rules: [rule]))
        } else {
            ruleGroups[0].rules.append(rule)
        }
        commitKvpCollections(named: "Add Rule")
    }

    public func deleteRule(_ id: UUID) {
        for index in ruleGroups.indices {
            ruleGroups[index].rules.removeAll { $0.id == id }
        }
        commitKvpCollections(named: "Delete Rule")
    }

    /// Replaces a rule in place, wherever it lives.
    public func updateRule(_ rule: Rule) {
        for group in ruleGroups.indices {
            if let index = ruleGroups[group].rules.firstIndex(where: { $0.id == rule.id }) {
                ruleGroups[group].rules[index] = rule
                commitKvpCollections(named: "Edit Rule")
                return
            }
        }
    }

    /// Turns one rule off without deleting it — `isActive` has been honoured by
    /// the engine and stored all along, with no way to set it.
    public func setRuleActive(_ id: UUID, _ active: Bool) {
        for group in ruleGroups.indices {
            if let index = ruleGroups[group].rules.firstIndex(where: { $0.id == id }) {
                ruleGroups[group].rules[index].isActive = active
                commitKvpCollections(named: active ? "Enable Rule" : "Disable Rule")
                return
            }
        }
    }

    // MARK: Groups

    /// Groups exist in the model, are ordered, and can be switched off as a
    /// set — the UI flattened them away with `flatMap(\.rules)`, so a book
    /// could carry them but nobody could make or use one.
    @discardableResult
    public func addRuleGroup(named name: String) -> UUID {
        let group = RuleGroup(name: name)
        ruleGroups.append(group)
        commitKvpCollections(named: "Add Rule Group")
        return group.id
    }

    public func deleteRuleGroup(_ id: UUID) {
        ruleGroups.removeAll { $0.id == id }
        commitKvpCollections(named: "Delete Rule Group")
    }

    public func renameRuleGroup(_ id: UUID, to name: String) {
        guard let index = ruleGroups.firstIndex(where: { $0.id == id }) else { return }
        ruleGroups[index].name = name
        commitKvpCollections(named: "Rename Rule Group")
    }

    public func setRuleGroupActive(_ id: UUID, _ active: Bool) {
        guard let index = ruleGroups.firstIndex(where: { $0.id == id }) else { return }
        ruleGroups[index].isActive = active
        commitKvpCollections(named: active ? "Enable Rule Group" : "Disable Rule Group")
    }

    /// Rules are evaluated in order and `stopProcessing` cuts the rest off, so
    /// the order is a real setting rather than presentation.
    public func moveRules(inGroup id: UUID, from offsets: IndexSet, to destination: Int) {
        guard let index = ruleGroups.firstIndex(where: { $0.id == id }) else { return }
        ruleGroups[index].rules.move(fromOffsets: offsets, toOffset: destination)
        commitKvpCollections(named: "Reorder Rules")
    }

    public func moveRuleGroups(from offsets: IndexSet, to destination: Int) {
        ruleGroups.move(fromOffsets: offsets, toOffset: destination)
        commitKvpCollections(named: "Reorder Rule Groups")
    }

    /// Convenience: evaluate the document's rules against a context.
    func ruleOutcome(description: String, memo: String = "", amount: Decimal = 0) -> RuleOutcome {
        RuleEngine.evaluate(ruleGroups,
                            context: RuleContext(description: description, memo: memo, amount: amount))
    }

    // MARK: Apply to historical transactions (FR-RULE-02)

    /// Runs the document's rules over existing transactions and returns the
    /// changes they would make, without mutating anything. A change is proposed
    /// only when it is safe and non-empty: re-pointing an existing income/
    /// expense leg to a different category, and/or setting differing notes.
    public func previewHistoricalRules() -> [RuleApplication] {
        guard let book, !ruleGroups.isEmpty else { return [] }
        var items: [RuleApplication] = []
        for txn in book.transactions {
            let amount = txn.splits.map(\.value).max { abs($0) < abs($1) } ?? 0
            let outcome = RuleEngine.evaluate(ruleGroups, context: RuleContext(
                description: txn.transactionDescription,
                memo: txn.splits.first?.memo ?? "", amount: amount,
                accountNames: txn.splits.compactMap { $0.account?.name }))
            guard outcome.accountID != nil || outcome.notes != nil
                    || !outcome.tags.isEmpty || outcome.descriptionText != nil
                    || outcome.goalID != nil else { continue }

            let categoryLeg = txn.splits.first { isCategory($0.account?.type) }
            var proposedID: GncGUID?
            var proposedName: String?
            if let target = outcome.accountID.flatMap({ book.account(with: $0) }),
               isCategory(target.type), categoryLeg?.account?.guid != target.guid {
                proposedID = target.guid
                proposedName = target.name
            }
            let proposedNotes = (outcome.notes != nil && outcome.notes != txn.notes) ? outcome.notes : nil
            let newTags = outcome.tags.filter { !txn.tags.contains($0) }
            let proposedDescription = (outcome.descriptionText != nil
                && outcome.descriptionText != txn.transactionDescription) ? outcome.descriptionText : nil
            // Allocate the transaction's magnitude to the goal, when the goal
            // still exists.
            let goal = outcome.goalID.flatMap { id in savingsGoals.first { $0.id == id } }
            guard proposedID != nil || proposedNotes != nil || !newTags.isEmpty
                    || proposedDescription != nil || goal != nil else { continue }

            items.append(RuleApplication(
                id: txn.guid, description: txn.transactionDescription,
                currentCategory: categoryLeg?.account?.name,
                proposedCategory: proposedName, proposedCategoryID: proposedID,
                proposedNotes: proposedNotes,
                proposedTags: newTags, proposedDescription: proposedDescription,
                proposedGoalID: goal?.id, proposedGoalName: goal?.name,
                allocateAmount: goal != nil ? abs(amount) : 0))
        }
        return items
    }

    /// Applies the given previewed changes, re-pointing the income/expense leg
    /// and setting notes. Amounts and balance are untouched.
    public func applyHistoricalRules(_ items: [RuleApplication]) {
        guard let book, !items.isEmpty else { return }
        editing(items.map(\.id), named: "Apply Rules") {
            for item in items {
                guard let txn = book.transaction(with: item.id) else { continue }
                if let catID = item.proposedCategoryID, let target = book.account(with: catID),
                   let leg = txn.splits.first(where: { isCategory($0.account?.type) }) {
                    leg.account = target
                }
                if let notes = item.proposedNotes { txn.notes = notes }
                if !item.proposedTags.isEmpty {
                    txn.tags = (txn.tags + item.proposedTags.filter { !txn.tags.contains($0) })
                }
                if let description = item.proposedDescription { txn.transactionDescription = description }
            }
        }
        // Goal allocations aren't transaction edits — they adjust the KVP-backed
        // goals collection. Aggregate the deltas and commit them as one change.
        var goalDeltas: [GncGUID: Decimal] = [:]
        for item in items {
            guard let goalID = item.proposedGoalID else { continue }
            goalDeltas[goalID, default: 0] += item.allocateAmount
        }
        if !goalDeltas.isEmpty {
            for (goalID, delta) in goalDeltas {
                guard let index = savingsGoals.firstIndex(where: { $0.id == goalID }) else { continue }
                savingsGoals[index].savedAmount = max(0, savingsGoals[index].savedAmount + delta)
            }
            commitKvpCollections(named: "Apply Rules — Allocate to Goals")
        }
    }

    private func isCategory(_ type: AccountType?) -> Bool {
        type == .income || type == .expense
    }
}

/// A single proposed change from applying rules to a historical transaction.
public struct RuleApplication: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var description: String
    public var currentCategory: String?
    public var proposedCategory: String?
    public var proposedCategoryID: GncGUID?
    public var proposedNotes: String?
    /// Tags a rule would add (only those not already present).
    public var proposedTags: [String] = []
    /// A description a rule would set (payee cleanup), if different.
    public var proposedDescription: String?
    /// A savings goal a rule would allocate the transaction's amount to.
    public var proposedGoalID: GncGUID?
    public var proposedGoalName: String?
    /// The amount to earmark to ``proposedGoalID`` (the transaction's magnitude).
    public var allocateAmount: Decimal = 0
}
