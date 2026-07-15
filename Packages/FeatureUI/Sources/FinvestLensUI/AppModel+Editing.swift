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

    public func updateAccount(id: GncGUID, name: String, code: String, description: String,
                              notes: String, isPlaceholder: Bool, isHidden: Bool) {
        guard let book, let account = book.account(with: id) else { return }
        editingWholeBook(named: "Edit Account") {
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

        editingWholeBook(named: "Cascade Account Properties") {
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
        editingWholeBook(named: "Move Account") {
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

    /// Runs a structured query, replacing whatever search is showing.
    ///
    /// GnuCash finds *splits* and opens them as a register. We roll the hits up
    /// to their transactions — one row per transaction, as the results table
    /// already shows — but keep which split matched, so "Show in Register"
    /// opens the account the user actually searched for rather than guessing.
    public func runFind(_ query: FindQuery) {
        guard let book else { return }
        // Order matters: emptying the bar fires `runSearch`, so `findQuery` is
        // set after that has run rather than before it.
        searchQuery = ""
        searchNotices = []
        findQuery = query

        var matched: [GncGUID: GncGUID] = [:]
        var ordered: [Transaction] = []
        for split in book.splitsMatching(query) {
            guard let txn = split.transaction else { continue }
            if matched[txn.guid] == nil {
                matched[txn.guid] = split.guid
                ordered.append(txn)
            }
        }
        findMatchedSplitID = matched
        searchResults = ordered
            .sorted { $0.datePosted > $1.datePosted }
            .map { summary(for: $0) }
    }

    /// Ends a structured find, returning the detail pane to the register.
    public func clearFind() {
        findQuery = nil
        findMatchedSplitID = [:]
        searchResults = []
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
