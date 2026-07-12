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

    /// Where rule groups are stored inside the book's key-value slots.
    private static let ruleGroupsKey = "finvestlens/ruleGroups"

    /// The document's categorisation rules (persisted with the book).
    public var ruleGroups: [RuleGroup] {
        get {
            guard let book,
                  case let .string(json)? = book.kvp[Self.ruleGroupsKey],
                  let data = json.data(using: .utf8),
                  let groups = try? JSONDecoder().decode([RuleGroup].self, from: data)
            else { return [] }
            return groups
        }
        set {
            guard let book else { return }
            if newValue.isEmpty {
                book.kvp[Self.ruleGroupsKey] = nil
            } else if let data = try? JSONEncoder().encode(newValue),
                      let json = String(data: data, encoding: .utf8) {
                book.kvp[Self.ruleGroupsKey] = .string(json)
            }
            markDirtyAndRefresh()
        }
    }

    /// Adds a categorisation rule to the first (or a new) group.
    public func addRule(_ rule: Rule) {
        var groups = ruleGroups
        if groups.isEmpty {
            groups.append(RuleGroup(name: "Rules", rules: [rule]))
        } else {
            groups[0].rules.append(rule)
        }
        ruleGroups = groups
    }

    public func deleteRule(_ id: UUID) {
        var groups = ruleGroups
        for index in groups.indices {
            groups[index].rules.removeAll { $0.id == id }
        }
        ruleGroups = groups
    }

    /// Convenience: evaluate the document's rules against a context.
    func ruleOutcome(description: String, memo: String = "", amount: Decimal = 0) -> RuleOutcome {
        RuleEngine.evaluate(ruleGroups,
                            context: RuleContext(description: description, memo: memo, amount: amount))
    }
}
