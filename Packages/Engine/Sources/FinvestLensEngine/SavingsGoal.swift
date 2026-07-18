//
//  SavingsGoal.swift
//  FinvestLens — Engine
//
//  A savings goal ("piggy bank", `FR-GOAL-01`): a named target that earmarks
//  part of an asset account's balance. Money is added to or removed from the
//  goal without moving it between accounts — the goal is a read-model over one
//  account, adopted from Firefly III (docs/enhancements-firefly.md), not a
//  GnuCash concept. Goals are stored as one JSON collection in a book KVP slot.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A named savings goal earmarking part of an asset account.
public struct SavingsGoal: Identifiable, Codable, Hashable, Sendable {
    public var id: GncGUID
    public var name: String
    /// The asset account whose balance this goal draws from (nil = unlinked).
    public var accountGUID: GncGUID?
    /// The amount aimed for.
    public var targetAmount: Decimal
    /// The amount set aside so far.
    public var savedAmount: Decimal
    /// An optional date to reach the target by.
    public var targetDate: Date?
    /// An optional group name for organising goals (Firefly's object groups).
    public var group: String
    public var notes: String

    public init(id: GncGUID = .random(), name: String, accountGUID: GncGUID? = nil,
                targetAmount: Decimal = 0, savedAmount: Decimal = 0,
                targetDate: Date? = nil, group: String = "", notes: String = "") {
        self.id = id; self.name = name; self.accountGUID = accountGUID
        self.targetAmount = targetAmount; self.savedAmount = savedAmount
        self.targetDate = targetDate; self.group = group; self.notes = notes
    }

    /// Older slots predate `group`/`notes`/`targetDate`; decode them as absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(GncGUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        accountGUID = try c.decodeIfPresent(GncGUID.self, forKey: .accountGUID)
        targetAmount = try c.decode(Decimal.self, forKey: .targetAmount)
        savedAmount = try c.decode(Decimal.self, forKey: .savedAmount)
        targetDate = try c.decodeIfPresent(Date.self, forKey: .targetDate)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    /// The amount still to save (never below zero).
    public var remaining: Decimal { max(0, targetAmount - savedAmount) }

    /// Whether the target has been reached.
    public var isComplete: Bool { targetAmount > 0 && savedAmount >= targetAmount }

    /// Progress toward the target, clamped to `0...1` (0 when no target is set).
    public var fractionComplete: Double {
        guard targetAmount > 0 else { return 0 }
        let fraction = (savedAmount as NSDecimalNumber).doubleValue
            / (targetAmount as NSDecimalNumber).doubleValue
        return min(1, max(0, fraction))
    }
}
