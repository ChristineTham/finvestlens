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

    /// The account a split posts to (for the leg account picker).
    public func accountID(ofSplit splitID: GncGUID) -> GncGUID? {
        book?.split(with: splitID)?.account?.guid
    }

    /// Whether a row's transaction is simple enough for inline edits that touch
    /// money: exactly two legs, both in the transaction currency.
    public func isSimpleTransfer(splitID: GncGUID) -> Bool {
        guard let book, let split = book.split(with: splitID),
              let txn = split.transaction else { return false }
        return txn.splits.count == 2
            && txn.splits.allSatisfy { $0.account?.commodity == txn.currency }
    }

    /// Re-dates a transaction (journal headings address it directly; register
    /// rows via their split).
    public func inlineSetDate(transactionID: GncGUID, to date: Date) {
        guard let book, let txn = book.transaction(with: transactionID),
              txn.datePosted != date else { return }
        editing([txn.guid], named: "Edit Date") { txn.datePosted = date }
    }

    public func inlineSetDate(splitID: GncGUID, to date: Date) {
        guard let id = transactionID(ofSplit: splitID) else { return }
        inlineSetDate(transactionID: id, to: date)
    }

    /// Renames a transaction.
    public func inlineSetDescription(transactionID: GncGUID, to text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        guard let book, let txn = book.transaction(with: transactionID),
              !cleaned.isEmpty, txn.transactionDescription != cleaned else { return }
        editing([txn.guid], named: "Edit Description") { txn.transactionDescription = cleaned }
    }

    public func inlineSetDescription(splitID: GncGUID, to text: String) {
        guard let id = transactionID(ofSplit: splitID) else { return }
        inlineSetDescription(transactionID: id, to: text)
    }

    /// Sets a transaction's notes (the Double Line field). Empty clears them.
    public func inlineSetNotes(transactionID: GncGUID, to text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        guard let book, let txn = book.transaction(with: transactionID),
              txn.notes != cleaned else { return }
        editing([txn.guid], named: "Edit Notes") { txn.notes = cleaned }
    }

    public func inlineSetNotes(splitID: GncGUID, to text: String) {
        guard let id = transactionID(ofSplit: splitID) else { return }
        inlineSetNotes(transactionID: id, to: text)
    }

    /// Sets a split's memo. Empty clears it.
    public func inlineSetMemo(splitID: GncGUID, to text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        guard let book, let split = book.split(with: splitID),
              let txn = split.transaction, split.memo != cleaned else { return }
        editing([txn.guid], named: "Edit Memo") { split.memo = cleaned }
    }

    /// Moves *this* leg to another account (journal legs, expanded Auto-Split
    /// legs). Same-currency destinations only — a security or foreign-currency
    /// account needs the editor's quantity handling.
    @discardableResult
    public func inlineSetLegAccount(splitID: GncGUID, to accountID: GncGUID) -> Bool {
        guard let book, let split = book.split(with: splitID),
              let txn = split.transaction,
              let account = book.account(with: accountID),
              account.commodity == txn.currency,
              split.account !== account
        else { return false }
        editing([txn.guid], named: "Edit Account") { split.account = account }
        return true
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
