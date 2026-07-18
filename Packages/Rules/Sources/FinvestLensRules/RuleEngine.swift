//
//  RuleEngine.swift
//  FinvestLens — Rules
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The fields a rule evaluates against — a transaction being categorised.
public struct RuleContext: Sendable {
    public var description: String
    public var memo: String
    public var amount: Decimal
    /// Names of the accounts this transaction touches (for `account` triggers).
    public var accountNames: [String]

    public init(description: String, memo: String = "", amount: Decimal = 0,
                accountNames: [String] = []) {
        self.description = description
        self.memo = memo
        self.amount = amount
        self.accountNames = accountNames
    }
}

/// The combined effect of the rules that matched a context.
public struct RuleOutcome: Equatable, Sendable {
    /// Destination/counter account chosen by a rule (categorisation).
    public var accountID: GncGUID?
    /// Notes to attach.
    public var notes: String?
    /// Tags to add (accumulated across matching rules).
    public var tags: [String]
    /// Replacement description, if a rule set one.
    public var descriptionText: String?
    /// Savings goal to earmark the matched amount to, if a rule set one.
    public var goalID: GncGUID?
    /// `true` if a matched rule requested stop-processing.
    public var stopped: Bool

    public init(accountID: GncGUID? = nil, notes: String? = nil, tags: [String] = [],
                descriptionText: String? = nil, goalID: GncGUID? = nil, stopped: Bool = false) {
        self.accountID = accountID
        self.notes = notes
        self.tags = tags
        self.descriptionText = descriptionText
        self.goalID = goalID
        self.stopped = stopped
    }
}

/// Evaluates rule groups against a context (`FR-RULE-01`).
///
/// Groups are processed in order; within a group, active rules are tested. A
/// matching rule's actions accumulate into the outcome; `stopProcessing` halts
/// evaluation. Later matches override earlier ones for single-valued effects
/// (account, notes).
public enum RuleEngine {

    public static func evaluate(_ groups: [RuleGroup], context: RuleContext) -> RuleOutcome {
        var outcome = RuleOutcome()
        for group in groups where group.isActive {
            for rule in group.rules where rule.isActive {
                guard matches(rule, context) else { continue }
                apply(rule.actions, to: &outcome)
                if rule.stopProcessing {
                    outcome.stopped = true
                    return outcome
                }
            }
        }
        return outcome
    }

    // MARK: Matching

    static func matches(_ rule: Rule, _ context: RuleContext) -> Bool {
        guard !rule.triggers.isEmpty else { return false }
        return rule.matchAll
            ? rule.triggers.allSatisfy { matches($0, context) }
            : rule.triggers.contains { matches($0, context) }
    }

    static func matches(_ trigger: RuleTrigger, _ context: RuleContext) -> Bool {
        switch trigger.field {
        case .description: return matchesText(context.description, trigger)
        case .memo: return matchesText(context.memo, trigger)
        case .amount: return matchesAmount(context.amount, trigger)
        case .account: return context.accountNames.contains { matchesText($0, trigger) }
        }
    }

    private static func matchesText(_ field: String, _ trigger: RuleTrigger) -> Bool {
        let haystack = field.lowercased()
        let needle = trigger.value.lowercased()
        switch trigger.op {
        case .contains: return haystack.contains(needle)
        case .equals: return haystack == needle
        case .startsWith: return haystack.hasPrefix(needle)
        case .endsWith: return haystack.hasSuffix(needle)
        case .greaterThan, .lessThan: return false
        }
    }

    private static func matchesAmount(_ amount: Decimal, _ trigger: RuleTrigger) -> Bool {
        guard let value = Decimal(string: trigger.value) else { return false }
        switch trigger.op {
        case .equals: return amount == value
        case .greaterThan: return amount > value
        case .lessThan: return amount < value
        case .contains, .startsWith, .endsWith: return false
        }
    }

    // MARK: Applying

    private static func apply(_ actions: [RuleAction], to outcome: inout RuleOutcome) {
        for action in actions {
            switch action {
            case .setAccount(let guid): outcome.accountID = guid
            case .setNotes(let notes): outcome.notes = notes
            case .setTags(let tags):
                for tag in tags where !outcome.tags.contains(tag) { outcome.tags.append(tag) }
            case .setDescription(let text): outcome.descriptionText = text
            case .allocateToGoal(let guid): outcome.goalID = guid
            }
        }
    }
}
