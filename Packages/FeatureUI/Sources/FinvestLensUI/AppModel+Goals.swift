//
//  AppModel+Goals.swift
//  FinvestLens — FeatureUI
//
//  Savings goals / piggy banks (`FR-GOAL-01`). Goals are a read-model over asset
//  accounts, stored as one JSON collection in a book KVP slot (like scheduled
//  transactions and budgets), so each change is one undoable whole-book edit.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

@MainActor
extension AppModel {

    /// Asset-like accounts a goal can earmark (bank, cash, asset), non-placeholder.
    public var goalEligibleAccounts: [AccountNode] {
        postableAccounts.filter {
            $0.typeName == AccountType.bank.rawValue
                || $0.typeName == AccountType.cash.rawValue
                || $0.typeName == AccountType.asset.rawValue
        }
    }

    /// Adds a savings goal and persists it.
    public func addSavingsGoal(_ goal: SavingsGoal) {
        savingsGoals.append(goal)
        commitKvpCollections(named: "Add Savings Goal")
    }

    /// Replaces a goal (matched by id) with an edited copy.
    public func updateSavingsGoal(_ goal: SavingsGoal) {
        guard let index = savingsGoals.firstIndex(where: { $0.id == goal.id }) else { return }
        savingsGoals[index] = goal
        commitKvpCollections(named: "Edit Savings Goal")
    }

    public func deleteSavingsGoal(_ id: GncGUID) {
        savingsGoals.removeAll { $0.id == id }
        commitKvpCollections(named: "Delete Savings Goal")
    }

    /// Moves `amount` into (`+`) or out of (`-`) a goal's set-aside total, never
    /// below zero. Adding to a goal only earmarks money already in the account —
    /// no transaction is posted.
    public func adjustSavingsGoal(_ id: GncGUID, by amount: Decimal) {
        guard let index = savingsGoals.firstIndex(where: { $0.id == id }) else { return }
        savingsGoals[index].savedAmount = max(0, savingsGoals[index].savedAmount + amount)
        commitKvpCollections(named: amount >= 0 ? "Add to Savings Goal" : "Withdraw from Savings Goal")
    }

    /// The goals earmarking a given account, for the "already allocated" check.
    public func savingsGoals(forAccount id: GncGUID) -> [SavingsGoal] {
        savingsGoals.filter { $0.accountGUID == id }
    }

    /// How much of `accountID`'s balance is already earmarked by other goals —
    /// used to warn when a goal's saved total plus its siblings exceeds the
    /// account balance.
    public func earmarkedTotal(forAccount id: GncGUID, excluding goalID: GncGUID? = nil) -> Decimal {
        savingsGoals
            .filter { $0.accountGUID == id && $0.id != goalID }
            .reduce(Decimal(0)) { $0 + $1.savedAmount }
    }
}
