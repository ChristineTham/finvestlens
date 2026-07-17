//
//  Budget.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A budgeted amount for one account. GnuCash budgets hold a distinct value per
/// (account, period); this line carries a flat ``amount`` used for every period
/// plus optional ``periodAmounts`` that override specific periods — so a simple
/// "same each month" budget stays one number, while an imported GnuCash budget
/// with per-period figures is represented exactly.
public struct BudgetLine: Identifiable, Codable, Hashable, Sendable {
    public var id: GncGUID { accountGUID }
    public var accountGUID: GncGUID
    /// The default budgeted amount, applied to any period without a specific
    /// override (a spending limit for expense accounts).
    public var amount: Decimal
    /// Per-period overrides, keyed by zero-based period index.
    public var periodAmounts: [Int: Decimal]
    /// Envelope budgeting: carry the prior period's unspent (or overspent)
    /// remainder into this account's effective budget (`FR-BUD-02`).
    public var rollover: Bool

    public init(accountGUID: GncGUID, amount: Decimal,
                periodAmounts: [Int: Decimal] = [:], rollover: Bool = false) {
        self.accountGUID = accountGUID
        self.amount = amount
        self.periodAmounts = periodAmounts
        self.rollover = rollover
    }

    /// The budgeted amount for `period`: its override if set, else the flat
    /// ``amount``.
    public func amount(inPeriod period: Int) -> Decimal {
        periodAmounts[period] ?? amount
    }

    private enum CodingKeys: String, CodingKey { case accountGUID, amount, periodAmounts, rollover }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountGUID = try c.decode(GncGUID.self, forKey: .accountGUID)
        amount = try c.decode(Decimal.self, forKey: .amount)
        // Tolerate budgets saved before per-period amounts / rollover existed.
        periodAmounts = try c.decodeIfPresent([Int: Decimal].self, forKey: .periodAmounts) ?? [:]
        rollover = try c.decodeIfPresent(Bool.self, forKey: .rollover) ?? false
    }
}

/// A named budget: per-account planned amounts over a number of periods
/// (`FR-BUD-01`). GnuCash's `gnc_budget`.
///
/// A value type persisted with the book. Budget-vs-actual comparison lives in
/// the Reports layer.
public struct Budget: Identifiable, Codable, Hashable, Sendable {
    public var id: GncGUID
    public var name: String
    public var lines: [BudgetLine]
    /// How many periods the budget spans (GnuCash `num_periods`; default 12).
    public var numPeriods: Int

    public init(id: GncGUID = .random(), name: String, lines: [BudgetLine] = [],
                numPeriods: Int = 12) {
        self.id = id
        self.name = name
        self.lines = lines
        self.numPeriods = max(1, numPeriods)
    }

    private enum CodingKeys: String, CodingKey { case id, name, lines, numPeriods }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(GncGUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lines = try c.decodeIfPresent([BudgetLine].self, forKey: .lines) ?? []
        numPeriods = try c.decodeIfPresent(Int.self, forKey: .numPeriods) ?? 12
    }

    /// The flat budgeted amount for an account, or `nil` if not budgeted.
    public func amount(for accountGUID: GncGUID) -> Decimal? {
        lines.first { $0.accountGUID == accountGUID }?.amount
    }

    /// The budgeted amount for an (account, period). Matches GnuCash's
    /// `gnc_budget_get_account_period_value`: an account with no line reads as
    /// **zero**, not "unbudgeted".
    public func amount(for accountGUID: GncGUID, period: Int) -> Decimal {
        lines.first { $0.accountGUID == accountGUID }?.amount(inPeriod: period) ?? 0
    }

    /// Sets (or replaces) the flat budgeted amount for an account.
    public mutating func setAmount(_ amount: Decimal, for accountGUID: GncGUID) {
        if let index = lines.firstIndex(where: { $0.accountGUID == accountGUID }) {
            lines[index].amount = amount
        } else {
            lines.append(BudgetLine(accountGUID: accountGUID, amount: amount))
        }
    }

    /// Sets the budgeted amount for a specific (account, period).
    public mutating func setAmount(_ amount: Decimal, for accountGUID: GncGUID, period: Int) {
        if let index = lines.firstIndex(where: { $0.accountGUID == accountGUID }) {
            lines[index].periodAmounts[period] = amount
        } else {
            lines.append(BudgetLine(accountGUID: accountGUID, amount: 0,
                                    periodAmounts: [period: amount]))
        }
    }

    /// Toggles envelope rollover for an account's line.
    public mutating func setRollover(_ rollover: Bool, for accountGUID: GncGUID) {
        if let index = lines.firstIndex(where: { $0.accountGUID == accountGUID }) {
            lines[index].rollover = rollover
        }
    }
}
