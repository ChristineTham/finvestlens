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
}
