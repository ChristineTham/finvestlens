//
//  Book.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The top-level container for a set of accounts, transactions, and commodities
/// — the in-memory source of truth (Architecture §3).
///
/// `Book` owns the object graph: the root account (and its subtree), all
/// transactions (which own their splits), and the commodity table. Balances are
/// computed here because the `Book` is the only object that sees every split.
public final class Book {

    /// Stable identity, preserved across GnuCash round-trips.
    public let guid: GncGUID

    /// The invisible root of the account tree.
    public let rootAccount: Account

    /// All transactions in the book.
    public private(set) var transactions: [Transaction]

    /// Known commodities (currencies and securities).
    public private(set) var commodities: [Commodity]

    /// The price database (`FR-ENG-09`).
    public private(set) var prices: [Price]

    /// Preserved book-level key-value slots.
    public var kvp: KvpFrame

    /// Designated initialiser adopting an existing root account (used when
    /// importing, so the root's GnuCash GUID is preserved).
    public init(
        guid: GncGUID = .random(),
        rootAccount: Account,
        kvp: KvpFrame = KvpFrame()
    ) {
        self.guid = guid
        self.rootAccount = rootAccount
        self.transactions = []
        self.commodities = []
        self.prices = []
        self.kvp = kvp
    }

    /// Creates an empty book with a fresh root account denominated in
    /// `baseCurrency`.
    public convenience init(
        guid: GncGUID = .random(),
        baseCurrency: Commodity = .aud,
        kvp: KvpFrame = KvpFrame()
    ) {
        let root = Account(name: "Root Account", type: .root, commodity: baseCurrency)
        self.init(guid: guid, rootAccount: root, kvp: kvp)
        registerCommodity(baseCurrency)
    }

    // MARK: Accounts

    /// All accounts in the tree, excluding the invisible root.
    public var accounts: [Account] { rootAccount.descendants }

    /// Adds `account` under `parent` (default: the root account).
    @discardableResult
    public func addAccount(_ account: Account, under parent: Account? = nil) -> Account {
        (parent ?? rootAccount).addChild(account)
        registerCommodity(account.commodity)
        return account
    }

    /// Looks up an account by GUID.
    public func account(with guid: GncGUID) -> Account? {
        accounts.first { $0.guid == guid }
    }

    // MARK: Commodities

    /// Adds a commodity to the table if not already present.
    public func registerCommodity(_ commodity: Commodity) {
        if !commodities.contains(commodity) {
            commodities.append(commodity)
        }
    }

    // MARK: Prices

    /// Updates a commodity's display metadata (name / fraction) across every
    /// account, price and the commodity table. Identity (namespace + mnemonic)
    /// is unchanged, so prices and quotes stay linked (`FR-INV-07`).
    public func updateCommodityMetadata(_ commodity: Commodity, fullName: String?, smallestFraction: Int?) {
        func apply(_ c: inout Commodity) {
            if let fullName, !fullName.isEmpty { c.fullName = fullName }
            if let smallestFraction, smallestFraction >= 1 { c.smallestFraction = smallestFraction }
        }
        for account in accounts where account.commodity == commodity { apply(&account.commodity) }
        for index in prices.indices where prices[index].commodity == commodity { apply(&prices[index].commodity) }
        for index in commodities.indices where commodities[index] == commodity { apply(&commodities[index]) }
    }

    /// Adds a price to the database (and registers its commodities).
    @discardableResult
    public func addPrice(_ price: Price) -> Price {
        registerCommodity(price.commodity)
        registerCommodity(price.currency)
        prices.append(price)
        return price
    }

    /// Removes a price by GUID.
    public func removePrice(_ guid: GncGUID) {
        prices.removeAll { $0.guid == guid }
    }

    /// The most recent price of `commodity` in `currency` on or before `date`
    /// (or the latest overall when `date` is `nil`).
    public func latestPrice(of commodity: Commodity, in currency: Commodity,
                            on date: Date? = nil) -> Price? {
        var best: Price?
        for price in prices {
            guard price.commodity == commodity, price.currency == currency else { continue }
            if let date, price.date > date { continue }
            if best == nil || price.date > best!.date {
                best = price
            }
        }
        return best
    }

    /// Values `quantity` units of `commodity` in `currency` using the price
    /// database. Returns `quantity` unchanged when the commodities match, or
    /// `nil` when no price is available.
    public func value(of quantity: Decimal, commodity: Commodity,
                      in currency: Commodity, on date: Date? = nil) -> Decimal? {
        if commodity == currency { return quantity }
        guard let price = latestPrice(of: commodity, in: currency, on: date) else { return nil }
        return quantity * price.value
    }

    // MARK: Cost basis / lots

    /// The chronological acquisition/disposal events for a security `account`,
    /// derived from its non-voided splits (`FR-INV-04`).
    public func lotEvents(for account: Account) -> [LotEvent] {
        var events: [LotEvent] = []
        for transaction in transactions {
            for split in transaction.splits
            where split.account === account && split.reconcileState != .voided
                && (split.quantity != 0 || split.action == "ReturnOfCapital") {
                events.append(LotEvent(date: transaction.datePosted,
                                       quantity: split.quantity, value: split.value,
                                       isSplit: split.action == "Split",
                                       isReturnOfCapital: split.action == "ReturnOfCapital"))
            }
        }
        return events
    }

    /// Computes cost basis, open lots and realised gains for a security
    /// `account` under `method`.
    public func costBasis(
        for account: Account,
        method: CostBasisMethod = .fifo,
        longTermThresholdDays: Int = CostBasis.defaultLongTermThresholdDays
    ) -> CostBasisResult {
        CostBasis.compute(events: lotEvents(for: account), method: method,
                          longTermThresholdDays: longTermThresholdDays)
    }

    // MARK: Transactions

    /// Adds a transaction to the book.
    @discardableResult
    public func addTransaction(_ transaction: Transaction) -> Transaction {
        registerCommodity(transaction.currency)
        transactions.append(transaction)
        return transaction
    }

    /// Removes a transaction (and detaches its splits).
    public func removeTransaction(_ transaction: Transaction) {
        transactions.removeAll { $0 === transaction }
        for split in transaction.splits { split.transaction = nil }
    }

    /// Looks up a transaction by GUID.
    public func transaction(with guid: GncGUID) -> Transaction? {
        transactions.first { $0.guid == guid }
    }

    /// All distinct tags used across transactions, sorted (`FR-TAG-01`).
    public var allTags: [String] {
        var seen = Set<String>()
        for transaction in transactions {
            for tag in transaction.tags { seen.insert(tag) }
        }
        return seen.sorted()
    }

    /// Looks up a split by GUID across all transactions.
    public func split(with guid: GncGUID) -> Split? {
        for transaction in transactions {
            if let split = transaction.splits.first(where: { $0.guid == guid }) { return split }
        }
        return nil
    }

    /// All splits posted to `account` across every transaction.
    public func splits(for account: Account) -> [Split] {
        transactions.flatMap { $0.splits }.filter { $0.account === account }
    }

    // MARK: Balances

    /// Whether a split should be counted at a given reconcile filter.
    /// Voided splits never count toward a balance.
    private static func matches(_ split: Split, _ filter: BalanceFilter) -> Bool {
        guard split.reconcileState != .voided else { return false }
        switch filter {
        case .all:
            return true
        case .cleared:
            return split.reconcileState == .cleared || split.reconcileState == .reconciled
        case .reconciled:
            return split.reconcileState == .reconciled
        }
    }

    /// The balance of `account` in its own commodity, summing split quantities.
    ///
    /// - Parameters:
    ///   - account: the account to total.
    ///   - filter: which splits to include (all / cleared / reconciled).
    ///   - includingDescendants: also include child-account balances (only valid
    ///     when children share the same commodity).
    public func balance(
        of account: Account,
        filter: BalanceFilter = .all,
        includingDescendants: Bool = false
    ) -> Money {
        var total = Decimal(0)
        let targets = includingDescendants ? [account] + account.descendants : [account]
        let targetSet = Set(targets.map { ObjectIdentifier($0) })
        for transaction in transactions {
            for split in transaction.splits {
                guard let acct = split.account,
                      targetSet.contains(ObjectIdentifier(acct)),
                      Book.matches(split, filter)
                else { continue }
                total += split.quantity
            }
        }
        return Money(total, account.commodity)
    }
}

/// Which splits to include when computing a balance.
public enum BalanceFilter: Sendable {
    /// Every split.
    case all
    /// Cleared or reconciled splits.
    case cleared
    /// Reconciled splits only.
    case reconciled
}
