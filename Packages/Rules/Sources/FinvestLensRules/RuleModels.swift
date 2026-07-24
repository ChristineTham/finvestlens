//
//  RuleModels.swift
//  FinvestLens — Rules
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A transaction field a trigger can test.
public enum RuleField: String, Codable, Sendable, CaseIterable {
    case description
    case memo
    case amount
    /// The name of an account the transaction touches.
    case account
}

/// How a trigger compares a field to its value.
public enum RuleOperator: String, Codable, Sendable, CaseIterable {
    case contains
    case equals
    case startsWith
    case endsWith
    case greaterThan
    case lessThan
}

/// A single condition, e.g. *description contains "Woolworths"*.
public struct RuleTrigger: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var field: RuleField
    public var op: RuleOperator
    public var value: String

    public init(id: UUID = UUID(), field: RuleField, op: RuleOperator, value: String) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }
}

/// A change a rule applies when it matches.
public enum RuleAction: Codable, Hashable, Sendable {
    /// Categorise: set the counter/destination account.
    case setAccount(GncGUID)
    /// Append a note.
    case setNotes(String)
    /// Add cross-cutting tags to the transaction (`FR-RULE-01`).
    case setTags([String])
    /// Replace the transaction description (payee cleanup, `FR-RULE-01`).
    case setDescription(String)
    /// Earmark the matched transaction's amount to a savings goal
    /// (`FR-RULE-01` allocate-to-goal / `FR-GOAL-01`).
    case allocateToGoal(GncGUID)
    /// Mark the matched transaction as the payment of a bill (a scheduled
    /// transaction) — bill reminders then treat that period exactly, without
    /// the description heuristic (`FR-RULE-01` link-to-bill).
    case linkToBill(GncGUID)
}

/// A rule: match some triggers (all or any), then apply actions.
public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var triggers: [RuleTrigger]
    /// `true` = all triggers must match (AND); `false` = any (OR).
    public var matchAll: Bool
    public var actions: [RuleAction]
    /// Stop evaluating further rules once this one matches.
    public var stopProcessing: Bool
    public var isActive: Bool

    public init(id: UUID = UUID(), name: String, triggers: [RuleTrigger] = [],
                matchAll: Bool = true, actions: [RuleAction] = [],
                stopProcessing: Bool = false, isActive: Bool = true) {
        self.id = id
        self.name = name
        self.triggers = triggers
        self.matchAll = matchAll
        self.actions = actions
        self.stopProcessing = stopProcessing
        self.isActive = isActive
    }
}

/// An ordered, toggleable group of rules.
public struct RuleGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isActive: Bool
    public var rules: [Rule]

    public init(id: UUID = UUID(), name: String, isActive: Bool = true, rules: [Rule] = []) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.rules = rules
    }
}
