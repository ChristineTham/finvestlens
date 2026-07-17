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
///
/// A split carries more than a UI can sensibly show — reconcile state and date,
/// preserved KVP slots, its own identity. Rather than widen this type until it
/// mirrors ``Split``, an edit **reuses the split object** the row came from and
/// assigns only the fields below; see
/// ``AppModel/updateTransaction(id:date:description:currency:splits:tags:)``.
/// ``splitID`` is what makes that possible, so a row that came from an existing
/// split must carry it.
public struct SplitInput: Identifiable, Hashable, Sendable {
    public var id = UUID()
    /// The existing split this row edits, or `nil` for a newly added leg.
    public var splitID: GncGUID?
    public var accountID: GncGUID?
    public var value: Decimal
    /// Amount in the account's own commodity (e.g. share count for a security).
    /// `nil` defaults to `value`, correct for same-currency cash postings.
    public var quantity: Decimal?
    public var memo: String
    /// GnuCash's per-split Action (e.g. "Buy", "Withdrawal", a cheque number).
    public var action: String

    public init(splitID: GncGUID? = nil, accountID: GncGUID? = nil, value: Decimal = 0,
                quantity: Decimal? = nil, memo: String = "", action: String = "") {
        self.splitID = splitID
        self.accountID = accountID
        self.value = value
        self.quantity = quantity
        self.memo = memo
        self.action = action
    }
}

/// A named, persisted structured Find query (`FR-FIND-01`).
///
/// GnuCash cannot do this — its Find dialog forgets everything on close — and
/// it is the obvious missing piece once queries take six criteria to build.
public struct SavedFindQuery: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var query: FindQuery

    public init(id: UUID = UUID(), name: String, query: FindQuery) {
        self.id = id
        self.name = name
        self.query = query
    }
}

/// A named, persisted search query (`FR-FIND-01`).
public struct SavedSearch: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var query: String

    public init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }
}

/// Something the free-text query did that the user did not ask for.
public enum SearchNotice: Identifiable, Hashable, Sendable {
    /// `key:` is not an operator, so the whole token was searched as text.
    case unknownKey(String)

    public var id: String {
        switch self {
        case .unknownKey(let key): "unknownKey.\(key)"
        }
    }

    public var message: String {
        switch self {
        case .unknownKey(let key):
            "“\(key):” isn’t a search key, so it was searched for as ordinary text."
        }
    }

    public var recovery: String {
        switch self {
        case .unknownKey:
            "Keys are tag:, account:, memo:, desc: and amount:. To search by date, "
            + "amount range, reconcile state or notes, use Find (⌘F)."
        }
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
    public var tags: [String] = []
    /// GnuCash's transaction Notes — the second line of a double-line register.
    public var notes: String = ""
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
                               splits: [SplitInput], tags: [String] = [],
                               notes: String = "") throws -> GncGUID {
        guard let book else { throw TransactionEntryError.noBook }
        let realSplits = splits.filter { $0.accountID != nil }
        guard realSplits.count >= 2 else { throw TransactionEntryError.tooFewSplits }

        let txn = Transaction(currency: currency, datePosted: date,
                              description: description, notes: notes)
        for input in realSplits {
            guard let id = input.accountID, let account = book.account(with: id) else {
                throw TransactionEntryError.unknownAccount
            }
            txn.addSplit(Split(account: account, value: input.value, quantity: input.quantity,
                               memo: input.memo, action: input.action))
        }
        txn.tags = tags
        guard txn.isBalanced else {
            throw TransactionEntryError.unbalanced(txn.imbalance.rounded.amount)
        }
        editing([txn.guid], named: "Add Transaction") {
            book.addTransaction(txn)
        }
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
                // Preserve share counts when the quantity differs from the value
                // (security / foreign-currency legs). `splitID` is what lets the
                // save reuse this very split rather than build a replacement.
                SplitInput(splitID: $0.guid, accountID: $0.account?.guid, value: $0.value,
                           quantity: $0.quantity == $0.value ? nil : $0.quantity,
                           memo: $0.memo, action: $0.action)
            },
            tags: txn.tags,
            notes: txn.notes
        )
    }

    /// Replaces a transaction's fields and splits in place, re-validating the
    /// double-entry invariant (`FR-REG-02`).
    @discardableResult
    public func updateTransaction(id: GncGUID, date: Date, description: String,
                                  currency: Commodity, splits: [SplitInput],
                                  tags: [String]? = nil,
                                  notes: String? = nil) throws -> GncGUID {
        guard let book, let txn = book.transaction(with: id) else { throw TransactionEntryError.notFound }
        let realSplits = splits.filter { $0.accountID != nil }
        guard realSplits.count >= 2 else { throw TransactionEntryError.tooFewSplits }
        let residual = currency.round(realSplits.reduce(Decimal(0)) { $0 + $1.value })
        guard residual == 0 else { throw TransactionEntryError.unbalanced(residual) }

        // Resolve the accounts before touching anything: an unknown one has to
        // throw with the transaction still intact, not halfway rewritten.
        let resolved: [(account: Account, input: SplitInput)] = try realSplits.map { input in
            guard let accountID = input.accountID, let account = book.account(with: accountID) else {
                throw TransactionEntryError.unknownAccount
            }
            return (account, input)
        }

        // The rows are re-attached to the splits they came from, so that a save
        // carries everything the editor never showed: reconcile state and date,
        // the split's identity, and its preserved slots. Rebuilding them instead
        // — which is what this did — silently cleared the reconcile state of any
        // transaction anyone edited, and the values still balanced, so nothing
        // downstream could notice.
        let reusable = Dictionary(txn.splits.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })

        editing([id], named: "Edit Transaction") {
            txn.datePosted = date
            // `dateEntered` is when the transaction was entered, not when it was
            // last touched: GnuCash sets it once and leaves it. Assigning the
            // posting date here rewrote it on every edit, which the register's
            // "Date of Entry" sort would then order by.
            txn.transactionDescription = description
            txn.currency = currency
            if let tags { txn.tags = tags }
            if let notes { txn.notes = notes }
            for existing in Array(txn.splits) { txn.removeSplit(existing) }
            for (account, input) in resolved {
                if let splitID = input.splitID, let split = reusable[splitID] {
                    split.account = account
                    split.value = input.value
                    split.quantity = input.quantity ?? input.value
                    split.memo = input.memo
                    split.action = input.action
                    txn.addSplit(split)
                } else {
                    txn.addSplit(Split(account: account, value: input.value,
                                       quantity: input.quantity, memo: input.memo,
                                       action: input.action))
                }
            }
        }
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

    /// The account a transaction is best opened in.
    ///
    /// The balance-sheet leg — the bank account or card the money actually
    /// moved through — because that is the register a person thinks in. Taking
    /// the first split instead lands you in the *category*, and imported
    /// transactions are written category-leg-first.
    ///
    /// `Imbalance-*`/`Orphan-*` are skipped even though they are typed `.bank`:
    /// on this book every imported transaction has one, and landing there tells
    /// you nothing about where the money went. Falls back to the first split
    /// when there is no real balance-sheet leg (a category-to-category
    /// correction), because the result still has to open somewhere.
    public func registerAccountID(forTransaction id: GncGUID) -> GncGUID? {
        guard let txn = book?.transaction(with: id) else { return nil }
        let onBalanceSheet = txn.splits.first { split in
            guard let account = split.account, !account.isImbalanceOrOrphan else { return false }
            switch account.type {
            case .bank, .cash, .credit, .asset, .liability, .stock, .mutualFund,
                 .receivable, .payable:
                return true
            default:
                return false
            }
        }
        return (onBalanceSheet ?? txn.splits.first)?.account?.guid
    }

    /// Opens a transaction in its register, selected and scrolled to.
    ///
    /// Clearing the query is the point, not a side effect: a non-empty search
    /// keeps the results in the detail pane, so without this the register the
    /// caller asked for would never come on screen.
    public func showInRegister(_ id: GncGUID) {
        guard let book, let txn = book.transaction(with: id) else { return }

        // A structured find already knows which split matched, so use it rather
        // than re-deriving one: if you searched "Account is AGL", the AGL leg is
        // the answer, even though the heuristic would prefer the cash leg.
        let matchedSplit = findMatchedSplitID[id].flatMap { book.split(with: $0) }
        guard let accountID = matchedSplit?.account?.guid
                ?? registerAccountID(forTransaction: id) else { return }

        searchQuery = ""                 // → runSearch() empties the results
        clearFind()
        selectedAccountID = accountID    // → refreshRegister()
        pendingRegisterSplitID = matchedSplit?.guid
            ?? txn.splits.first { $0.account?.guid == accountID }?.guid
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

    // MARK: Tax report options (GnuCash Edit ▸ Tax Report Options)

    /// One account's tax-reporting settings and its balance over the tax period.
    public struct TaxAccount: Identifiable, Sendable {
        public let id: GncGUID
        public var name: String
        public var typeName: String
        public var taxRelated: Bool
        public var taxCode: String?
        /// Sign-adjusted balance over the tax period, in the account's currency.
        public var periodBalance: Decimal
        public var currencyCode: String
    }

    /// Income and expense accounts (the ones a tax schedule draws on), with
    /// their tax flags and their balance over `[from, to]`. Tax-flagged first,
    /// then by name, so the schedule reads top-down.
    public func taxAccounts(from: Date, to: Date) -> [TaxAccount] {
        guard let book else { return [] }
        let balances = book.balancesByAccount(from: from, to: to)
        return book.accounts
            .filter { ($0.type == .income || $0.type == .expense) && !$0.isPlaceholder }
            .map { account in
                let raw = balances[ObjectIdentifier(account)] ?? 0
                // Sign-adjust so income and expense both read positive.
                let signed = account.type.normalBalanceIsDebit ? raw : -raw
                return TaxAccount(
                    id: account.guid, name: account.fullName,
                    typeName: account.type.rawValue.capitalized,
                    taxRelated: account.taxRelated, taxCode: account.taxCode,
                    periodBalance: account.commodity.round(signed),
                    currencyCode: account.commodity.mnemonic)
            }
            .sorted { ($0.taxRelated ? 0 : 1, $0.name) < ($1.taxRelated ? 0 : 1, $1.name) }
    }

    /// Sets an account's tax-related flag and category code. Undoable.
    public func setAccountTax(id: GncGUID, related: Bool, code: String?) {
        guard let book, let account = book.account(with: id) else { return }
        editingAccounts([id], named: "Tax Options") {
            account.taxRelated = related
            account.taxCode = related ? code : nil
        }
    }

    // MARK: Period-end close (GnuCash Tools ▸ Close Book)

    /// Equity accounts a period close can post its result into, as (id, name).
    public var equityAccountChoices: [(id: GncGUID, name: String)] {
        guard let book else { return [] }
        return book.accounts
            .filter { $0.type == .equity && !$0.isPlaceholder }
            .map { ($0.guid, $0.fullName) }
            .sorted { $0.name < $1.name }
    }

    /// The net result of a close in one currency, for the preview.
    public struct ClosingCurrencyPreview: Identifiable, Sendable {
        public var currencyCode: String
        /// The amount landing in equity, sign-adjusted so a profit reads
        /// positive (retained earnings grew).
        public var netToEquity: Decimal
        public var id: String { currencyCode }
    }

    /// Previews a period-end close without touching the book: how many income/
    /// expense accounts have a balance to move, and the net per currency.
    ///
    /// Nets are reported *per currency*, never blended — a book spanning AUD
    /// and USD income closes into one balanced transaction each, and adding
    /// their quantities into a single figure would be a sum of unlike units.
    public func closingPreview(asOf date: Date, equityID: GncGUID)
        -> (accounts: Int, byCurrency: [ClosingCurrencyPreview])? {
        guard let book, let equity = book.account(with: equityID) else { return nil }
        let result = BookClosing.build(in: book, asOf: date, into: equity)
        let byCurrency = result.transactions.map { txn in
            let equityQuantity = txn.splits
                .filter { $0.account === equity }
                .reduce(Decimal(0)) { $0 + $1.value }
            // The equity leg carries the P&L quantity sum; negate so a profit
            // (credit-normal income) shows as a positive addition to equity.
            return ClosingCurrencyPreview(currencyCode: txn.currency.mnemonic,
                                          netToEquity: -equityQuantity)
        }
        return (result.closedAccountCount, byCurrency)
    }

    /// Posts the period-end closing transactions, moving income/expense balances
    /// into `equityID` as of `date`. Undoable as one action. Returns the number
    /// of accounts closed, or `nil` if the book or account is missing.
    @discardableResult
    public func closeBook(asOf date: Date, equityID: GncGUID,
                          description: String = "Closing Entries") -> Int? {
        guard let book, let equity = book.account(with: equityID) else { return nil }
        let result = BookClosing.build(in: book, asOf: date, into: equity, description: description)
        guard !result.transactions.isEmpty else { return 0 }
        editingWholeBook(named: "Close Book") {
            for txn in result.transactions { book.addTransaction(txn) }
        }
        return result.closedAccountCount
    }

    public func updateAccount(id: GncGUID, name: String, code: String, description: String,
                              notes: String, isPlaceholder: Bool, isHidden: Bool) {
        guard let book, let account = book.account(with: id) else { return }
        editingAccounts([id], named: "Edit Account") {
            account.name = name
            account.code = code
            account.accountDescription = description
            account.notes = notes
            account.isPlaceholder = isPlaceholder
            account.isHidden = isHidden
        }
    }

    // MARK: Cascade account properties (FR-ACC-02)

    /// Which of an account's properties to push down its subtree.
    ///
    /// Each is opt-in and applied independently, because they are unrelated
    /// decisions: colouring a subtree to match its parent is routine, hiding one
    /// is not, and doing the second because you asked for the first would be a
    /// surprise. GnuCash's dialog offers the same three with the same tick boxes
    /// — colour, placeholder, hidden — and nothing else, since name, code and
    /// notes are what tell two accounts apart.
    public struct CascadeOptions: Sendable, Equatable {
        public var color = false
        public var isPlaceholder = false
        public var isHidden = false

        public init(color: Bool = false, isPlaceholder: Bool = false, isHidden: Bool = false) {
            self.color = color
            self.isPlaceholder = isPlaceholder
            self.isHidden = isHidden
        }

        public var isEmpty: Bool { !color && !isPlaceholder && !isHidden }
    }

    /// Copies the chosen properties from `id` onto every account beneath it
    /// (GnuCash's Cascade Account Properties), and returns how many it changed.
    ///
    /// The whole subtree, not just the children: a property that stopped one
    /// level down would leave the tree in a state you could not have asked for
    /// and could not see. `Account.descendants` has always been there for this.
    @discardableResult
    public func cascadeProperties(from id: GncGUID, _ options: CascadeOptions) -> Int {
        guard let book, let account = book.account(with: id), !options.isEmpty else { return 0 }
        let targets = account.descendants
        guard !targets.isEmpty else { return 0 }

        editingAccounts(targets.map(\.guid), named: "Cascade Account Properties") {
            for target in targets {
                if options.color { target.color = account.color }
                if options.isPlaceholder { target.isPlaceholder = account.isPlaceholder }
                if options.isHidden { target.isHidden = account.isHidden }
            }
        }
        return targets.count
    }

    /// How many accounts a cascade from `id` would touch.
    public func descendantCount(of id: GncGUID) -> Int {
        book?.account(with: id)?.descendants.count ?? 0
    }

    // MARK: Transaction operations

    public func deleteTransaction(_ id: GncGUID) {
        guard let book, let txn = book.transaction(with: id) else { return }
        editing([id], named: "Delete Transaction") {
            book.removeTransaction(txn)
        }
    }

    /// Deletes the transaction that owns a given split (register-row action).
    public func deleteTransaction(forSplit splitID: GncGUID) {
        guard let book, let txn = book.split(with: splitID)?.transaction else { return }
        editing([txn.guid], named: "Delete Transaction") {
            book.removeTransaction(txn)
        }
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
        editing([copy.guid], named: "Duplicate Transaction") {
            book.addTransaction(copy)
        }
        return copy.guid
    }

    // MARK: Cut / Copy / Paste (FR-REG-09)

    /// Why a paste did not happen.
    public enum PasteError: Error, Equatable {
        case nothingToPaste
        /// An account the transaction posts to is not in this book, named so the
        /// message can say which.
        case unknownAccount(String)
    }

    /// Puts a transaction on the clipboard.
    @discardableResult
    public func copyTransaction(_ id: GncGUID) -> Bool {
        guard let book, let txn = book.transaction(with: id) else { return false }
        let legs = txn.splits.map { split in
            TransactionClipboard.Leg(
                accountGUID: split.account?.guid ?? .random(),
                accountFullName: split.account?.fullName ?? "",
                value: split.value,
                quantity: split.quantity,
                memo: split.memo,
                action: split.action)
        }
        TransactionPasteboard.write(TransactionClipboard(
            datePosted: txn.datePosted,
            number: txn.number,
            transactionDescription: txn.transactionDescription,
            notes: txn.notes,
            currency: txn.currency,
            legs: legs))
        return true
    }

    /// Copies a transaction and then deletes it. Two edits in the model, one
    /// action to the person doing it — so it is one Undo.
    @discardableResult
    public func cutTransaction(_ id: GncGUID) -> Bool {
        guard copyTransaction(id), let book, let txn = book.transaction(with: id) else {
            return false
        }
        editing([id], named: "Cut Transaction") {
            book.removeTransaction(txn)
        }
        return true
    }

    /// Pastes the clipboard's transaction into the book as a new one.
    ///
    /// Accounts resolve by GUID, then by full name — the second is what makes a
    /// paste into another book land where it should, since a GUID from someone
    /// else's file means nothing here. An account that answers to neither is
    /// refused by name rather than quietly re-pointed at Imbalance, which would
    /// be this feature deciding where someone's money went.
    ///
    /// The pasted transaction keeps the copied date, as Duplicate does, and
    /// arrives unreconciled: it is new, and nobody has agreed to it.
    @discardableResult
    public func pasteTransaction() throws -> GncGUID {
        guard let book else { throw PasteError.nothingToPaste }
        guard let clipboard = TransactionPasteboard.read() else { throw PasteError.nothingToPaste }

        var resolved: [(Account, TransactionClipboard.Leg)] = []
        for leg in clipboard.legs {
            guard let account = book.account(with: leg.accountGUID)
                    ?? book.accounts.first(where: { $0.fullName == leg.accountFullName })
            else {
                throw PasteError.unknownAccount(leg.accountFullName.isEmpty
                                                ? "an account" : leg.accountFullName)
            }
            resolved.append((account, leg))
        }
        guard !resolved.isEmpty else { throw PasteError.nothingToPaste }

        let txn = Transaction(currency: clipboard.currency, datePosted: clipboard.datePosted,
                              number: clipboard.number,
                              description: clipboard.transactionDescription,
                              notes: clipboard.notes)
        for (account, leg) in resolved {
            txn.addSplit(Split(account: account, value: leg.value, quantity: leg.quantity,
                               memo: leg.memo, action: leg.action))
        }
        editing([txn.guid], named: "Paste Transaction") {
            book.addTransaction(txn)
        }
        return txn.guid
    }

    /// Whether there is a transaction on the clipboard to paste.
    public var canPasteTransaction: Bool { TransactionPasteboard.hasTransaction }

    /// Why a paste was refused, in words.
    public func describe(_ error: PasteError) -> String {
        switch error {
        case .nothingToPaste:
            "There is no transaction on the clipboard."
        case .unknownAccount(let name):
            "This book has no account called “\(name)”, so there is nowhere for that part of "
            + "the transaction to go. Create it first, or paste into the book it came from."
        }
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
        editing([reversal.guid], named: "Add Reversing Transaction") {
            book.addTransaction(reversal)
        }
        return reversal.guid
    }

    /// Voids a transaction: its splits stop counting toward balances.
    public func voidTransaction(_ id: GncGUID) {
        guard let book, let txn = book.transaction(with: id) else { return }
        editing([id], named: "Void Transaction") {
            for split in txn.splits { split.reconcileState = .voided }
        }
    }

    /// Un-voids a transaction, returning its splits to unreconciled.
    ///
    /// The state each split held before the void is not recorded, so this
    /// cannot restore a prior `c`/`y` — unreconciled is the safe landing:
    /// it never claims a split was reconciled when it may not have been.
    public func unvoidTransaction(_ id: GncGUID) {
        guard let book, let txn = book.transaction(with: id) else { return }
        editing([id], named: "Unvoid Transaction") {
            for split in txn.splits where split.reconcileState == .voided {
                split.reconcileState = .notReconciled
            }
        }
    }

    /// Whether every split of a transaction is voided (drives Unvoid in the UI).
    public func isVoided(_ id: GncGUID) -> Bool {
        guard let book, let txn = book.transaction(with: id), !txn.splits.isEmpty else { return false }
        return txn.splits.allSatisfy { $0.reconcileState == .voided }
    }

    /// The GUID of the transaction owning a split (for register-row actions).
    public func transactionID(ofSplit splitID: GncGUID) -> GncGUID? {
        book?.split(with: splitID)?.transaction?.guid
    }

    /// A split's current reconcile state, for a menu that has to show a tick
    /// against it.
    public func reconcileState(ofSplit splitID: GncGUID) -> ReconcileState? {
        book?.split(with: splitID)?.reconcileState
    }

    /// Any split of a transaction, for a row that stands for the transaction
    /// rather than one of its legs — a journal heading, say. The per-transaction
    /// operations do not care which leg they are reached through.
    public func anySplitID(ofTransaction id: GncGUID) -> GncGUID? {
        book?.transaction(with: id)?.splits.first?.guid
    }

    /// Every tag in the book. `Book.allTags` has existed and been tested from
    /// the start with no caller: the editor's Tags field was free text, so the
    /// only way to reuse a tag was to remember how you spelled it, and a typo
    /// silently made a second tag.
    public var knownTags: [String] { book?.allTags ?? [] }

    /// Tags starting with `prefix` that are not already on the transaction being
    /// edited, for autocomplete. Matching on a prefix rather than anywhere is
    /// what makes the list shorten as you type.
    public func tagSuggestions(prefix: String, excluding used: [String] = []) -> [String] {
        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        let taken = Set(used.map { $0.lowercased() })
        return knownTags.filter {
            !taken.contains($0.lowercased())
                && (needle.isEmpty || $0.lowercased().hasPrefix(needle))
        }
    }

    // MARK: Reconciliation

    public func setReconcileState(splitID: GncGUID, to state: ReconcileState) {
        guard let book, let split = book.split(with: splitID),
              let txnID = split.transaction?.guid else { return }
        editing([txnID], named: "Change Reconcile State") {
            split.reconcileState = state
        }
    }

    /// Cycles a split n → c → y → n (register click behaviour).
    ///
    /// Voided and frozen splits are left alone: they are not part of the cycle,
    /// and folding them into it meant a stray click on the R column silently
    /// un-voided a transaction one split at a time. Use ``unvoidTransaction(_:)``
    /// to undo a void, and ``setReconcileState(splitID:to:)`` to set `f`.
    public func cycleReconcileState(splitID: GncGUID) {
        guard let book, let split = book.split(with: splitID),
              let txnID = split.transaction?.guid else { return }
        let next: ReconcileState
        switch split.reconcileState {
        case .notReconciled: next = .cleared
        case .cleared: next = .reconciled
        case .reconciled: next = .notReconciled
        case .voided, .frozen: return
        }
        editing([txnID], named: "Change Reconcile State") {
            split.reconcileState = next
        }
    }

    // MARK: Account structure

    /// The current parent of `id` (`nil` when it sits at the top level).
    public func parentID(ofAccount id: GncGUID) -> GncGUID? {
        guard let book, let account = book.account(with: id),
              let parent = account.parent, parent !== book.rootAccount
        else { return nil }
        return parent.guid
    }

    /// Valid re-parent destinations for `id`: every account except itself and
    /// its own descendants (which would create a cycle).
    public func validParents(forAccount id: GncGUID) -> [AccountNode] {
        guard let book, let account = book.account(with: id) else { return [] }
        let excluded = Set([account.guid] + account.descendants.map(\.guid))
        func flatten(_ nodes: [AccountNode]) -> [AccountNode] {
            nodes.flatMap { [$0] + flatten($0.children ?? []) }
        }
        return flatten(accountTree).filter { !excluded.contains($0.id) }
    }

    /// Reparents an account, refusing moves that would create a cycle
    /// (`FR-COA-02`). Returns `false` if the move is invalid.
    @discardableResult
    public func moveAccount(_ id: GncGUID, under newParentID: GncGUID?) -> Bool {
        guard let book, let account = book.account(with: id) else { return false }
        let newParent = newParentID.flatMap { book.account(with: $0) } ?? book.rootAccount
        if newParent === account || account.descendants.contains(where: { $0 === newParent }) {
            return false
        }
        editingAccounts([id], named: "Move Account") {
            newParent.addChild(account)   // addChild reparents from the old parent
        }
        return true
    }

    // MARK: Search (basic multi-field, `FR-REG-06`)

    func runSearch() {
        guard let book, !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            searchNotices = []
            return
        }
        findQuery = nil                  // typing replaces a structured find
        findMatchedSplitID = [:]
        searchNotices = notices(for: searchQuery)
        searchResults = transactionsMatching(searchQuery, in: book)
            .sorted { $0.datePosted > $1.datePosted }
            .map { summary(for: $0) }
    }

    // MARK: Structured find (GnuCash Edit ▸ Find…, `FR-FIND-01`)

    /// How a query relates to the results already showing — GnuCash's "Type of
    /// search". A search that took several refinements to get right is built a
    /// step at a time, not retyped as one giant query.
    public enum FindMode: String, CaseIterable, Identifiable, Sendable {
        /// Replace the results.
        case new
        /// Keep only current results that also match (narrow).
        case refine
        /// Add matches to the current results (widen).
        case add
        /// Remove matches from the current results.
        case delete

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .new: "New search"
            case .refine: "Refine current results"
            case .add: "Add to current results"
            case .delete: "Delete from current results"
            }
        }
    }

    /// Runs a structured query against the book, or against the current
    /// results, depending on `mode`.
    ///
    /// GnuCash finds *splits* and opens them as a register. We roll the hits up
    /// to their transactions — one row per transaction, as the results table
    /// already shows — but keep which split matched, so "Show in Register"
    /// opens the account the user actually searched for rather than guessing.
    /// The modes compose over the *split* set for the same reason the criteria
    /// test splits: refining "account is CDIA" by "is reconciled" must mean one
    /// split that is both.
    public func runFind(_ query: FindQuery, mode: FindMode = .new) {
        guard book != nil else { return }
        // Order matters: emptying the bar fires `runSearch`, so `findQuery` is
        // set after that has run rather than before it.
        searchQuery = ""
        searchNotices = []
        findQuery = query

        if mode == .new {
            findPipeline = [FindStep(query: query, mode: .new)]
        } else {
            findPipeline.append(FindStep(query: query, mode: mode))
        }
        recomputeFindResults()
    }

    /// Recomputes the results by replaying every search step against the book
    /// as it stands now.
    ///
    /// Two properties have to hold at once, and each rules out the obvious
    /// implementation of the other. Results are *live*: editing a result
    /// re-evaluates it, so a transaction edited out of the criteria leaves and
    /// one edited into them appears — which rules out freezing the matched set.
    /// And a *refined* result set stays refined across those edits — which
    /// rules out re-running just the last query, since that would silently
    /// undo the refine/add/delete steps that built the set. Replaying the
    /// whole pipeline is the only shape that gives both: every step stays in
    /// force, and every step is evaluated fresh.
    func recomputeFindResults() {
        guard let book else { return }
        var set: Set<GncGUID> = []
        for step in findPipeline {
            let matches = Set(book.splitsMatching(step.query).map(\.guid))
            switch step.mode {
            case .new: set = matches
            case .refine: set.formIntersection(matches)
            case .add: set.formUnion(matches)
            case .delete: set.subtract(matches)
            }
        }
        findSplitIDs = set

        // Roll up in book order so "first matched split" is deterministic.
        var matched: [GncGUID: GncGUID] = [:]
        var ordered: [Transaction] = []
        for txn in book.transactions {
            for split in txn.splits where findSplitIDs.contains(split.guid) {
                if matched[txn.guid] == nil {
                    matched[txn.guid] = split.guid
                    ordered.append(txn)
                }
            }
        }
        findMatchedSplitID = matched
        searchResults = ordered
            .sorted { $0.datePosted > $1.datePosted }
            .map { summary(for: $0) }
    }

    /// Whether there are results for refine/add/delete to work against.
    public var hasFindResults: Bool { !findSplitIDs.isEmpty }

    /// Ends a structured find, returning the detail pane to the register.
    public func clearFind() {
        findQuery = nil
        findPipeline = []
        findMatchedSplitID = [:]
        findSplitIDs = []
        searchResults = []
    }

    // MARK: In-register quick entry (FR-REG-05)

    /// GnuCash's blank row at the foot of the register, as an entry bar: date,
    /// description, transfer account, amount, Return. What the blank row is
    /// *for* is rapid two-split entry — the grocery run, the fuel stop — and a
    /// signed amount in the register's own convention (positive into this
    /// account) covers it. A multi-split entry is ⌘T's job, as it is GnuCash's
    /// splits button's.
    ///
    /// Returns the new transaction, and points the register at its new row —
    /// entering a transaction should end with it on screen, not somewhere below.
    @discardableResult
    public func quickEnter(into accountID: GncGUID, transferFrom transferID: GncGUID,
                           amount: Decimal, date: Date, description: String) -> GncGUID? {
        guard amount != 0, accountID != transferID else { return nil }
        guard let id = addTransfer(from: transferID, to: accountID,
                                   amount: amount, date: date, description: description)
        else { return nil }
        pendingRegisterSplitID = book?.transaction(with: id)?.splits
            .first { $0.account?.guid == accountID }?.guid
        return id
    }

    /// The most recent transaction under `description`, reduced to what the
    /// entry bar can hold: the other side and the signed amount into
    /// `accountID`. GnuCash's QuickFill fills the rest of the row the moment
    /// the description matches; two-split templates are the ones a two-split
    /// bar can honour, so others fill nothing rather than half of something.
    public func quickFill(forDescription description: String,
                          into accountID: GncGUID) -> (transferID: GncGUID, amount: Decimal)? {
        guard let template = template(forDescription: description),
              template.count == 2,
              let own = template.first(where: { $0.accountID == accountID }),
              let other = template.first(where: { $0.accountID != accountID }),
              let transferID = other.accountID
        else { return nil }
        return (transferID, own.value)
    }

    // MARK: Bulk operations on results (FR-FIND-03)

    /// Deletes several transactions as one edit — one action to the person who
    /// selected them, so one Undo.
    public func deleteTransactions(_ ids: [GncGUID]) {
        guard let book, !ids.isEmpty else { return }
        editing(ids, named: ids.count == 1 ? "Delete Transaction" : "Delete \(ids.count) Transactions") {
            for id in ids {
                if let txn = book.transaction(with: id) { book.removeTransaction(txn) }
            }
        }
    }

    /// Voids several transactions as one edit.
    public func voidTransactions(_ ids: [GncGUID]) {
        guard let book, !ids.isEmpty else { return }
        editing(ids, named: ids.count == 1 ? "Void Transaction" : "Void \(ids.count) Transactions") {
            for id in ids {
                guard let txn = book.transaction(with: id) else { continue }
                for split in txn.splits { split.reconcileState = .voided }
            }
        }
    }

    /// Sets the reconcile state of the *matched* split of each result — the leg
    /// the search was about, which is what makes "find last month's cheques,
    /// mark them cleared" mean the cheque account's legs and not the whole
    /// transaction. Only meaningful for a structured find, where each result
    /// remembers which split matched.
    public func setReconcileStateOfMatches(in ids: [GncGUID], to state: ReconcileState) {
        guard let book, !ids.isEmpty else { return }
        let splits = ids.compactMap { findMatchedSplitID[$0] }
        guard !splits.isEmpty else { return }
        editing(ids, named: "Change Reconcile State") {
            for splitID in splits {
                book.split(with: splitID)?.reconcileState = state
            }
        }
    }

    // MARK: Saved find queries

    /// Saves a query under a name. Same-name saves replace: "Untagged cash
    /// spending" twice is an update, not two entries answering differently as
    /// the book moves on.
    public func saveFindQuery(_ query: FindQuery, named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !trimmed.isEmpty else { return }
        savedFindQueries.removeAll { $0.name == trimmed }
        savedFindQueries.append(SavedFindQuery(name: trimmed, query: query))
        savedFindQueries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        commitKvpCollections(named: "Save Find Query")
    }

    public func deleteSavedFindQuery(_ id: UUID) {
        savedFindQueries.removeAll { $0.id == id }
        commitKvpCollections(named: "Delete Find Query")
    }

    /// The known `key:` operators, for both matching and telling the user what
    /// exists when they reach for one that doesn't.
    static let searchKeys: Set<String> = [
        "tag", "account", "acct", "memo", "desc", "description", "amount",
    ]

    /// A token like `date:2026` looks like an operator and is not one, so it is
    /// searched for as literal text. That is a reasonable thing to do — one of
    /// this book's descriptions really does read "Value Date: 09/04/2026" — but
    /// doing it *silently* is not: the query appears to run and simply finds
    /// nothing. Say what happened, and where the real thing lives.
    func notices(for query: String) -> [SearchNotice] {
        let tokens = query.split(separator: " ").map(String.init)
        var seen: [String] = []
        for token in tokens {
            guard let colon = token.firstIndex(of: ":") else { continue }
            let key = String(token[..<colon]).lowercased()
            guard !key.isEmpty, key.allSatisfy(\.isLetter) else { continue }
            guard !Self.searchKeys.contains(key), !seen.contains(key) else { continue }
            seen.append(key)
        }
        return seen.map { .unknownKey($0) }
    }

    /// Transactions matching an operator query. Whitespace-separated tokens are
    /// ANDed. A `key:value` token filters a field (`tag:`, `account:`, `memo:`,
    /// `desc:`, `amount:>N` / `amount:<N` / `amount:N`); any other token is
    /// free text matched against description / number / memo / account name
    /// (`FR-FIND-01`).
    func transactionsMatching(_ query: String, in book: Book) -> [Transaction] {
        let tokens = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return book.transactions.filter { txn in
            tokens.allSatisfy { matchesToken($0, txn) }
        }
    }

    private func matchesToken(_ token: String, _ txn: Transaction) -> Bool {
        if let colon = token.firstIndex(of: ":") {
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...]).lowercased()
            switch key {
            case "tag":
                return txn.tags.contains { $0.lowercased().contains(value) }
            case "account", "acct":
                return txn.splits.contains { $0.account?.name.lowercased().contains(value) ?? false }
            case "memo":
                return txn.splits.contains { $0.memo.lowercased().contains(value) }
            case "desc", "description":
                return txn.transactionDescription.lowercased().contains(value)
            case "amount":
                return matchesAmount(value, txn)
            default:
                break
            }
        }
        return matchesFreeText(token.lowercased(), txn)
    }

    private func matchesAmount(_ spec: String, _ txn: Transaction) -> Bool {
        let magnitude = txn.splits.map(\.value).map(abs).max() ?? 0
        if spec.hasPrefix(">"), let n = Decimal(string: String(spec.dropFirst())) { return magnitude > n }
        if spec.hasPrefix("<"), let n = Decimal(string: String(spec.dropFirst())) { return magnitude < n }
        if let n = Decimal(string: spec) { return magnitude == n }
        return false
    }

    private func matchesFreeText(_ needle: String, _ txn: Transaction) -> Bool {
        if txn.transactionDescription.lowercased().contains(needle) { return true }
        if txn.number.lowercased().contains(needle) { return true }
        for split in txn.splits {
            if split.memo.lowercased().contains(needle) { return true }
            if let name = split.account?.name.lowercased(), name.contains(needle) { return true }
        }
        return false
    }

    // MARK: Saved searches (`FR-FIND-01`)

    /// Saves the current query under `name`.
    public func saveCurrentSearch(name: String) {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let label = name.trimmingCharacters(in: .whitespaces)
        savedSearches.append(SavedSearch(name: label.isEmpty ? query : label, query: query))
        commitKvpCollections(named: "Save Search")
    }

    public func deleteSavedSearch(_ id: UUID) {
        savedSearches.removeAll { $0.id == id }
        commitKvpCollections(named: "Delete Saved Search")
    }

    /// Applies a saved search by setting the query (which re-runs the search).
    public func applySavedSearch(_ id: UUID) {
        guard let saved = savedSearches.first(where: { $0.id == id }) else { return }
        searchQuery = saved.query
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
        // No `splitID`: these rows are a template for a *new* transaction, and
        // carrying one would re-attach the save to the splits of the
        // transaction we copied from.
        return match.splits.map {
            SplitInput(accountID: $0.account?.guid, value: $0.value,
                       memo: $0.memo, action: $0.action)
        }
    }
}
