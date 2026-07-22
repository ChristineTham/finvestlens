//
//  AppModel+InlineEdit.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  In-place register editing (GnuCash-style): the selected row's date,
//  description, transfer account and amount edit directly in the table.
//  Money-touching edits are limited to simple two-leg same-currency
//  transactions — anything richer (splits, securities, multi-currency)
//  belongs in the transaction editor, where every leg is visible.
//

import Foundation
import FinvestLensEngine

@MainActor
extension AppModel {

    /// Whether a row's transaction is simple enough for inline edits that touch
    /// money: exactly two legs, both in the transaction currency.
    public func isSimpleTransfer(splitID: GncGUID) -> Bool {
        guard let book, let split = book.split(with: splitID),
              let txn = split.transaction else { return false }
        return txn.splits.count == 2
            && txn.splits.allSatisfy { $0.account?.commodity == txn.currency }
    }

    /// Re-dates the row's transaction.
    public func inlineSetDate(splitID: GncGUID, to date: Date) {
        guard let book, let split = book.split(with: splitID),
              let txn = split.transaction, txn.datePosted != date else { return }
        editing([txn.guid], named: "Edit Date") { txn.datePosted = date }
    }

    /// Renames the row's transaction.
    public func inlineSetDescription(splitID: GncGUID, to text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        guard let book, let split = book.split(with: splitID),
              let txn = split.transaction, !cleaned.isEmpty,
              txn.transactionDescription != cleaned else { return }
        editing([txn.guid], named: "Edit Description") { txn.transactionDescription = cleaned }
    }

    /// Sets the row leg's amount and rebalances the counter leg. Two-leg
    /// same-currency transactions only; returns whether the edit applied.
    @discardableResult
    public func inlineSetAmount(splitID: GncGUID, to value: Decimal) -> Bool {
        guard let book, let split = book.split(with: splitID),
              let txn = split.transaction, txn.splits.count == 2,
              txn.splits.allSatisfy({ $0.account?.commodity == txn.currency }),
              let other = txn.splits.first(where: { $0 !== split })
        else { return false }
        let rounded = txn.currency.round(value)
        guard split.value != rounded else { return true }
        editing([txn.guid], named: "Edit Amount") {
            split.value = rounded
            split.quantity = rounded
            other.value = -rounded
            other.quantity = -rounded
        }
        return true
    }

    /// Moves the counter leg to another account (re-categorising the row).
    /// Two-leg transactions, same-currency destination only.
    @discardableResult
    public func inlineSetTransfer(splitID: GncGUID, to accountID: GncGUID) -> Bool {
        guard let book, let split = book.split(with: splitID),
              let txn = split.transaction, txn.splits.count == 2,
              let other = txn.splits.first(where: { $0 !== split }),
              let account = book.account(with: accountID),
              account.commodity == txn.currency,
              other.account !== account
        else { return false }
        editing([txn.guid], named: "Edit Transfer Account") { other.account = account }
        return true
    }
}
