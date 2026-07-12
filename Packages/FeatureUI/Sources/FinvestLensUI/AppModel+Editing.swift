//
//  AppModel+Editing.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One leg of a transaction being entered in the UI.
public struct SplitInput: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var accountID: GncGUID?
    public var value: Decimal
    public var memo: String

    public init(accountID: GncGUID? = nil, value: Decimal = 0, memo: String = "") {
        self.accountID = accountID
        self.value = value
        self.memo = memo
    }
}

/// A transaction-level row used by search results.
public struct TransactionSummary: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var date: Date
    public var description: String
    public var accounts: String
    public var amount: Decimal
    public var currencyCode: String
}

/// Errors from entering a transaction.
public enum TransactionEntryError: Error, Equatable {
    case noBook
    case tooFewSplits
    case unbalanced(Decimal)
    case unknownAccount
    case notFound
}

/// A snapshot of a transaction for pre-filling the editor.
public struct TransactionEdit: Sendable {
    public var date: Date
    public var description: String
    public var currency: Commodity
    public var splits: [SplitInput]
}

/// A snapshot of an account's editable fields.
public struct AccountEdit: Sendable {
    public var name: String
    public var code: String
    public var description: String
    public var notes: String
    public var isPlaceholder: Bool
    public var isHidden: Bool
}

@MainActor
extension AppModel {

    // MARK: Multi-split transaction entry

    /// Records a transaction from `splits`, validating that it balances
    /// (`FR-REG-02`). Throws ``TransactionEntryError`` otherwise.
    @discardableResult
    public func addTransaction(date: Date, description: String, currency: Commodity,
                               splits: [SplitInput]) throws -> GncGUID {
        guard let book else { throw TransactionEntryError.noBook }
        let realSplits = splits.filter { $0.accountID != nil }
        guard realSplits.count >= 2 else { throw TransactionEntryError.tooFewSplits }

        let txn = Transaction(currency: currency, datePosted: date, description: description)
        for input in realSplits {
            guard let id = input.accountID, let account = book.account(with: id) else {
                throw TransactionEntryError.unknownAccount
            }
            txn.addSplit(account: account, value: input.value, memo: input.memo)
        }
        guard txn.isBalanced else {
            throw TransactionEntryError.unbalanced(txn.imbalance.rounded.amount)
        }
        book.addTransaction(txn)
        markDirtyAndRefresh()
        return txn.guid
    }

    /// A snapshot of a transaction for editing, or `nil` if not found.
    public func editData(forTransaction id: GncGUID) -> TransactionEdit? {
        guard let book, let txn = book.transaction(with: id) else { return nil }
        return TransactionEdit(
            date: txn.datePosted,
            description: txn.transactionDescription,
            currency: txn.currency,
            splits: txn.splits.map {
                SplitInput(accountID: $0.account?.guid, value: $0.value, memo: $0.memo)
            }
        )
    }

    /// Replaces a transaction's fields and splits in place, re-validating the
    /// double-entry invariant (`FR-REG-02`).
    @discardableResult
    public func updateTransaction(id: GncGUID, date: Date, description: String,
                                  currency: Commodity, splits: [SplitInput]) throws -> GncGUID {
        guard let book, let txn = book.transaction(with: id) else { throw TransactionEntryError.notFound }
        let realSplits = splits.filter { $0.accountID != nil }
        guard realSplits.count >= 2 else { throw TransactionEntryError.tooFewSplits }
        let residual = currency.round(realSplits.reduce(Decimal(0)) { $0 + $1.value })
        guard residual == 0 else { throw TransactionEntryError.unbalanced(residual) }

        txn.datePosted = date
        txn.dateEntered = date
        txn.transactionDescription = description
        txn.currency = currency
        for existing in Array(txn.splits) { txn.removeSplit(existing) }
        for input in realSplits {
            guard let accountID = input.accountID, let account = book.account(with: accountID) else {
                throw TransactionEntryError.unknownAccount
            }
            txn.addSplit(account: account, value: input.value, memo: input.memo)
        }
        markDirtyAndRefresh()
        return txn.guid
    }

    // MARK: Register navigation

    /// The account on the "other side" of a split's transaction (for jump).
    public func otherAccountID(ofSplit splitID: GncGUID) -> GncGUID? {
        guard let book, let split = book.split(with: splitID), let txn = split.transaction else { return nil }
        return txn.splits.first { $0 !== split }?.account?.guid
    }

    /// Selects the counter-account of a split (GnuCash "Jump", `FR-REG-08`).
    public func jumpToOtherAccount(ofSplit splitID: GncGUID) {
        if let other = otherAccountID(ofSplit: splitID) { selectedAccountID = other }
    }

    // MARK: Account editing

    public func editData(forAccount id: GncGUID) -> AccountEdit? {
        guard let book, let account = book.account(with: id) else { return nil }
        return AccountEdit(
            name: account.name,
            code: account.code,
            description: account.accountDescription,
            notes: account.notes,
            isPlaceholder: account.isPlaceholder,
            isHidden: account.isHidden
        )
    }

    public func updateAccount(id: GncGUID, name: String, code: String, description: String,
                              notes: String, isPlaceholder: Bool, isHidden: Bool) {
        guard let book, let account = book.account(with: id) else { return }
        account.name = name
        account.code = code
        account.accountDescription = description
        account.notes = notes
        account.isPlaceholder = isPlaceholder
        account.isHidden = isHidden
        markDirtyAndRefresh()
    }

    // MARK: Transaction operations

    public func deleteTransaction(_ id: GncGUID) {
        guard let book, let txn = book.transaction(with: id) else { return }
        book.removeTransaction(txn)
        markDirtyAndRefresh()
    }

    /// Deletes the transaction that owns a given split (register-row action).
    public func deleteTransaction(forSplit splitID: GncGUID) {
        guard let book, let txn = book.split(with: splitID)?.transaction else { return }
        book.removeTransaction(txn)
        markDirtyAndRefresh()
    }

    @discardableResult
    public func duplicateTransaction(_ id: GncGUID) -> GncGUID? {
        guard let book, let source = book.transaction(with: id) else { return nil }
        let copy = Transaction(currency: source.currency, datePosted: source.datePosted,
                               number: source.number, description: source.transactionDescription,
                               notes: source.notes)
        for split in source.splits {
            copy.addSplit(Split(account: split.account, value: split.value,
                                quantity: split.quantity, memo: split.memo, action: split.action))
        }
        book.addTransaction(copy)
        markDirtyAndRefresh()
        return copy.guid
    }

    /// Adds a reversing transaction (negated splits) — GnuCash's "Add Reversing
    /// Transaction" (`FR-REG-08`).
    @discardableResult
    public func addReversingTransaction(_ id: GncGUID, date: Date? = nil) -> GncGUID? {
        guard let book, let source = book.transaction(with: id) else { return nil }
        let reversal = Transaction(
            currency: source.currency,
            datePosted: date ?? source.datePosted,
            description: "Reversal of \(source.transactionDescription)"
        )
        for split in source.splits {
            reversal.addSplit(Split(account: split.account, value: -split.value,
                                    quantity: -split.quantity, memo: split.memo))
        }
        book.addTransaction(reversal)
        markDirtyAndRefresh()
        return reversal.guid
    }

    /// Voids a transaction: its splits stop counting toward balances.
    public func voidTransaction(_ id: GncGUID) {
        guard let book, let txn = book.transaction(with: id) else { return }
        for split in txn.splits { split.reconcileState = .voided }
        markDirtyAndRefresh()
    }

    /// The GUID of the transaction owning a split (for register-row actions).
    public func transactionID(ofSplit splitID: GncGUID) -> GncGUID? {
        book?.split(with: splitID)?.transaction?.guid
    }

    // MARK: Reconciliation

    public func setReconcileState(splitID: GncGUID, to state: ReconcileState) {
        guard let book, let split = book.split(with: splitID) else { return }
        split.reconcileState = state
        markDirtyAndRefresh()
    }

    /// Cycles a split n → c → y → n (register click behaviour).
    public func cycleReconcileState(splitID: GncGUID) {
        guard let book, let split = book.split(with: splitID) else { return }
        switch split.reconcileState {
        case .notReconciled: split.reconcileState = .cleared
        case .cleared: split.reconcileState = .reconciled
        default: split.reconcileState = .notReconciled
        }
        markDirtyAndRefresh()
    }

    // MARK: Account structure

    /// Reparents an account, refusing moves that would create a cycle
    /// (`FR-COA-02`). Returns `false` if the move is invalid.
    @discardableResult
    public func moveAccount(_ id: GncGUID, under newParentID: GncGUID?) -> Bool {
        guard let book, let account = book.account(with: id) else { return false }
        let newParent = newParentID.flatMap { book.account(with: $0) } ?? book.rootAccount
        if newParent === account || account.descendants.contains(where: { $0 === newParent }) {
            return false
        }
        newParent.addChild(account)   // addChild reparents from the old parent
        markDirtyAndRefresh()
        return true
    }

    // MARK: Search (basic multi-field, `FR-REG-06`)

    func runSearch() {
        guard let book, !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        let needle = searchQuery.lowercased()
        searchResults = book.transactions.filter { matches($0, needle) }
            .sorted { $0.datePosted > $1.datePosted }
            .map { summary(for: $0) }
    }

    private func matches(_ txn: Transaction, _ needle: String) -> Bool {
        if txn.transactionDescription.lowercased().contains(needle) { return true }
        if txn.number.lowercased().contains(needle) { return true }
        for split in txn.splits {
            if split.memo.lowercased().contains(needle) { return true }
            if let name = split.account?.name.lowercased(), name.contains(needle) { return true }
        }
        return false
    }

    private func summary(for txn: Transaction) -> TransactionSummary {
        let debits = txn.splits.filter { $0.value > 0 }.reduce(Decimal(0)) { $0 + $1.value }
        let names = Set(txn.splits.compactMap { $0.account?.name })
        return TransactionSummary(
            id: txn.guid,
            date: txn.datePosted,
            description: txn.transactionDescription,
            accounts: names.sorted().joined(separator: ", "),
            amount: txn.currency.round(debits),
            currencyCode: txn.currency.mnemonic
        )
    }

    // MARK: QuickFill (`FR-REG-04`)

    /// Recent, distinct transaction descriptions matching `prefix`
    /// (case-insensitive), most-recent first.
    public func descriptionSuggestions(prefix: String, limit: Int = 5) -> [String] {
        guard let book, !prefix.isEmpty else { return [] }
        let needle = prefix.lowercased()
        var seen = Set<String>()
        var results: [String] = []
        for txn in book.transactions.sorted(by: { $0.datePosted > $1.datePosted }) {
            let description = txn.transactionDescription
            guard description.lowercased().hasPrefix(needle), !seen.contains(description) else { continue }
            seen.insert(description)
            results.append(description)
            if results.count >= limit { break }
        }
        return results
    }

    /// The splits of the most recent transaction whose description matches
    /// `description` exactly — used to pre-fill a new entry.
    public func template(forDescription description: String) -> [SplitInput]? {
        guard let book else { return nil }
        let match = book.transactions
            .filter { $0.transactionDescription.caseInsensitiveCompare(description) == .orderedSame }
            .max(by: { $0.datePosted < $1.datePosted })
        guard let match else { return nil }
        return match.splits.map { SplitInput(accountID: $0.account?.guid, value: $0.value, memo: $0.memo) }
    }
}
