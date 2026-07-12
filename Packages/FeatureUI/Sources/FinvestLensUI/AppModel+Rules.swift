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

    /// Adds a categorisation rule to the first (or a new) group.
    public func addRule(_ rule: Rule) {
        if ruleGroups.isEmpty {
            ruleGroups.append(RuleGroup(name: "Rules", rules: [rule]))
        } else {
            ruleGroups[0].rules.append(rule)
        }
        commitKvpCollections()
    }

    public func deleteRule(_ id: UUID) {
        for index in ruleGroups.indices {
            ruleGroups[index].rules.removeAll { $0.id == id }
        }
        commitKvpCollections()
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
                memo: txn.splits.first?.memo ?? "", amount: amount))
            guard outcome.accountID != nil || outcome.notes != nil else { continue }

            let categoryLeg = txn.splits.first { isCategory($0.account?.type) }
            var proposedID: GncGUID?
            var proposedName: String?
            if let target = outcome.accountID.flatMap({ book.account(with: $0) }),
               isCategory(target.type), categoryLeg?.account?.guid != target.guid {
                proposedID = target.guid
                proposedName = target.name
            }
            let proposedNotes = (outcome.notes != nil && outcome.notes != txn.notes) ? outcome.notes : nil
            guard proposedID != nil || proposedNotes != nil else { continue }

            items.append(RuleApplication(
                id: txn.guid, description: txn.transactionDescription,
                currentCategory: categoryLeg?.account?.name,
                proposedCategory: proposedName, proposedCategoryID: proposedID,
                proposedNotes: proposedNotes))
        }
        return items
    }

    /// Applies the given previewed changes, re-pointing the income/expense leg
    /// and setting notes. Amounts and balance are untouched.
    public func applyHistoricalRules(_ items: [RuleApplication]) {
        guard let book else { return }
        for item in items {
            guard let txn = book.transaction(with: item.id) else { continue }
            if let catID = item.proposedCategoryID, let target = book.account(with: catID),
               let leg = txn.splits.first(where: { isCategory($0.account?.type) }) {
                leg.account = target
            }
            if let notes = item.proposedNotes { txn.notes = notes }
        }
        if !items.isEmpty { markDirtyAndRefresh() }
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
}
