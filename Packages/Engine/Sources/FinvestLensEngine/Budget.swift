//
//  Budget.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A budgeted amount for one account (per period).
public struct BudgetLine: Identifiable, Codable, Hashable, Sendable {
    public var id: GncGUID { accountGUID }
    public var accountGUID: GncGUID
    /// Budgeted amount for the period (a spending limit for expense accounts).
    public var amount: Decimal
    /// Envelope budgeting: carry the prior period's unspent (or overspent)
    /// remainder into this account's effective budget (`FR-BUD-02`).
    public var rollover: Bool

    public init(accountGUID: GncGUID, amount: Decimal, rollover: Bool = false) {
        self.accountGUID = accountGUID
        self.amount = amount
        self.rollover = rollover
    }

    private enum CodingKeys: String, CodingKey { case accountGUID, amount, rollover }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountGUID = try c.decode(GncGUID.self, forKey: .accountGUID)
        amount = try c.decode(Decimal.self, forKey: .amount)
        // Tolerate budgets saved before rollover existed.
        rollover = try c.decodeIfPresent(Bool.self, forKey: .rollover) ?? false
    }
}

/// A named budget: per-account planned amounts for a period (`FR-BUD-01`).
///
/// A value type persisted with the book. Budget-vs-actual comparison lives in
/// the Reports layer.
public struct Budget: Identifiable, Codable, Hashable, Sendable {
    public var id: GncGUID
    public var name: String
    public var lines: [BudgetLine]

    public init(id: GncGUID = .random(), name: String, lines: [BudgetLine] = []) {
        self.id = id
        self.name = name
        self.lines = lines
    }

    /// The budgeted amount for an account, or `nil` if not budgeted.
    public func amount(for accountGUID: GncGUID) -> Decimal? {
        lines.first { $0.accountGUID == accountGUID }?.amount
    }

    /// Sets (or replaces) the budgeted amount for an account.
    public mutating func setAmount(_ amount: Decimal, for accountGUID: GncGUID) {
        if let index = lines.firstIndex(where: { $0.accountGUID == accountGUID }) {
            lines[index].amount = amount
        } else {
            lines.append(BudgetLine(accountGUID: accountGUID, amount: amount))
        }
    }

    /// Toggles envelope rollover for an account's line.
    public mutating func setRollover(_ rollover: Bool, for accountGUID: GncGUID) {
        if let index = lines.firstIndex(where: { $0.accountGUID == accountGUID }) {
            lines[index].rollover = rollover
        }
    }
}
