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
    ///
    /// Any change drops the lookup index rather than updating it: invalidation
    /// is O(1), so reading a book's 100k prices stays linear, and the rebuild
    /// is paid once on the next lookup.
    public private(set) var prices: [Price] {
        didSet { invalidatePriceIndex() }
    }

    /// Preserved book-level key-value slots.
    public var kvp: KvpFrame

    // MARK: Business objects (`FR-BUS-*`)

    public internal(set) var customers: [Customer]
    public internal(set) var vendors: [Vendor]
    public internal(set) var employees: [Employee]
    public internal(set) var jobs: [Job]
    public internal(set) var invoices: [Invoice]
    public internal(set) var billTerms: [BillTerm]
    public internal(set) var taxTables: [TaxTable]
    /// Business lots (A/R / A/P), keyed nowhere special — walked by account.
    public internal(set) var lots: [Lot]

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
        self.customers = []
        self.vendors = []
        self.employees = []
        self.jobs = []
        self.invoices = []
        self.billTerms = []
        self.taxTables = []
        self.lots = []
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

    /// Replaces the whole price database — the undo primitive for scoped
    /// price edits (a snapshot of `prices` is cheap: value types).
    public func replaceAllPrices(_ newPrices: [Price]) {
        prices = newPrices
    }

    /// Removes a price by GUID.
    public func removePrice(_ guid: GncGUID) {
        prices.removeAll { $0.guid == guid }
    }

    /// Removes every price matching `predicate` in a single pass. Used to wipe a
    /// security's history before rebuilding it (a per-GUID loop would be O(n²)).
    @discardableResult
    public func removePrices(where predicate: (Price) -> Bool) -> Int {
        let before = prices.count
        prices.removeAll(where: predicate)
        return before - prices.count
    }

    // MARK: Price index

    /// A quoted pair: what is priced, and what it is priced in.
    struct PricePair: Hashable {
        let commodity: Commodity
        let currency: Commodity
    }

    /// Prices bucketed by pair and by commodity, each bucket sorted by date.
    ///
    /// `latestPrice` used to scan the whole database — 26 ms on a 100k-price
    /// book — and the account tree asks for prices thousands of times per
    /// refresh, which is what made opening a real book take ~45s. Built lazily
    /// on first lookup and dropped whenever `prices` changes, so loading a book
    /// (100k appends) doesn't rebuild it once per price.
    private var pairIndex: [PricePair: [Price]]?
    private var commodityIndex: [Commodity: [Price]]?

    func invalidatePriceIndex() {
        pairIndex = nil
        commodityIndex = nil
    }

    /// Sorts a bucket by date, keeping insertion order within a date. The scan
    /// this replaces took the *first* price of the winning date in `prices`
    /// order, so ties must not be reordered or a duplicate-dated import would
    /// silently change a balance.
    private static func sortedByDate(_ bucket: [Price]) -> [Price] {
        bucket.enumerated()
            .sorted { $0.element.date == $1.element.date ? $0.offset < $1.offset
                                                        : $0.element.date < $1.element.date }
            .map(\.element)
    }

    private func buildIndexIfNeeded() {
        guard pairIndex == nil || commodityIndex == nil else { return }
        var pairs: [PricePair: [Price]] = [:]
        var byCommodity: [Commodity: [Price]] = [:]
        for price in prices {
            pairs[PricePair(commodity: price.commodity, currency: price.currency), default: []]
                .append(price)
            byCommodity[price.commodity, default: []].append(price)
        }
        pairIndex = pairs.mapValues(Self.sortedByDate)
        commodityIndex = byCommodity.mapValues(Self.sortedByDate)
    }

    /// The latest price in a date-sorted `bucket` on or before `date`, matching
    /// the linear scan it replaces: the first price of the winning date.
    private static func latest(in bucket: [Price], on date: Date?) -> Price? {
        // First index past the cut-off, by binary search.
        var low = 0, high = bucket.count
        if let date {
            while low < high {
                let mid = (low + high) / 2
                if bucket[mid].date > date { high = mid } else { low = mid + 1 }
            }
        } else {
            low = bucket.count
        }
        guard low > 0 else { return nil }
        // Rewind to the first price sharing the winning date.
        let winning = bucket[low - 1].date
        var first = low - 1
        while first > 0, bucket[first - 1].date == winning { first -= 1 }
        return bucket[first]
    }

    /// The most recent price of `commodity` in `currency` on or before `date`
    /// (or the latest overall when `date` is `nil`).
    public func latestPrice(of commodity: Commodity, in currency: Commodity,
                            on date: Date? = nil) -> Price? {
        buildIndexIfNeeded()
        guard let bucket = pairIndex?[PricePair(commodity: commodity, currency: currency)] else {
            return nil
        }
        return Self.latest(in: bucket, on: date)
    }

    /// The most recent price of `commodity` in any currency (index-backed
    /// counterpart of ``latestPrice(of:in:on:)``).
    func latestPricedAnyCurrency(of commodity: Commodity, on date: Date? = nil) -> Price? {
        buildIndexIfNeeded()
        guard let bucket = commodityIndex?[commodity] else { return nil }
        return Self.latest(in: bucket, on: date)
    }

    /// The price of `commodity` in `currency` *nearest in time* to `date` — the
    /// closer of the newest at-or-before and the oldest after, ties going to the
    /// earlier price. This is GnuCash's default report price source
    /// (`pricedb-nearest`, `gnc_pricedb_lookup_nearest_in_time`); valuations use
    /// it so a report as-of a date can pick a slightly-later quote.
    public func nearestPrice(of commodity: Commodity, in currency: Commodity,
                             on date: Date? = nil) -> Price? {
        buildIndexIfNeeded()
        guard let bucket = pairIndex?[PricePair(commodity: commodity, currency: currency)] else {
            return nil
        }
        return Self.nearest(in: bucket, on: date)
    }

    /// The nearest-in-time counterpart of ``latest(in:on:)``.
    private static func nearest(in bucket: [Price], on date: Date?) -> Price? {
        guard let date else { return latest(in: bucket, on: nil) }
        let before = latest(in: bucket, on: date)          // newest at-or-before
        // The oldest price strictly after `date`.
        var low = 0, high = bucket.count
        while low < high {
            let mid = (low + high) / 2
            if bucket[mid].date > date { high = mid } else { low = mid + 1 }
        }
        let after: Price? = low < bucket.count ? bucket[low] : nil
        switch (before, after) {
        case let (b?, a?):
            // Tie (equal distance) → the earlier price, matching GnuCash.
            return a.date.timeIntervalSince(date) < date.timeIntervalSince(b.date) ? a : b
        case let (b?, nil): return b
        case let (nil, a?): return a
        default: return nil
        }
    }

    /// Every commodity `commodity` has at least one price against, in either
    /// direction — the candidate intermediates for indirect FX conversion
    /// (GnuCash's `indirect_price_conversion` common-currency search).
    func pricedAgainst(_ commodity: Commodity) -> Set<Commodity> {
        buildIndexIfNeeded()
        var result: Set<Commodity> = []
        for pair in pairIndex?.keys ?? Dictionary<PricePair, [Price]>().keys {
            if pair.commodity == commodity { result.insert(pair.currency) }
            else if pair.currency == commodity { result.insert(pair.commodity) }
        }
        return result
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
    public func lotEvents(for account: Account, asOf: Date = .distantFuture) -> [LotEvent] {
        var events: [LotEvent] = []
        for transaction in transactions where transaction.datePosted <= asOf {
            // Brokerage/commission on the transaction: its expense-account
            // splits, shared equally across the transaction's security splits
            // (so a two-security swap doesn't double-count the fee).
            var brokerage = Decimal(0)
            var securitySplits = 0
            for split in transaction.splits where split.reconcileState != .voided {
                if let type = split.account?.type {
                    if type == .expense { brokerage += split.value }
                    else if type.isSecurityType && split.quantity != 0 { securitySplits += 1 }
                }
            }
            let feePerSecurity = securitySplits > 0 ? brokerage / Decimal(securitySplits) : 0

            for split in transaction.splits
            where split.account === account && split.reconcileState != .voided
                && (split.quantity != 0 || split.action == "ReturnOfCapital") {
                let isTrade = split.quantity != 0 && split.action != "Split"
                events.append(LotEvent(date: transaction.datePosted,
                                       quantity: split.quantity, value: split.value,
                                       isSplit: split.action == "Split",
                                       isReturnOfCapital: split.action == "ReturnOfCapital",
                                       fee: isTrade ? feePerSecurity : 0))
            }
        }
        return events
    }

    /// Computes cost basis, open lots and realised gains for a security
    /// `account` under `method`.
    public func costBasis(
        for account: Account,
        asOf: Date = .distantFuture,
        method: CostBasisMethod = .fifo,
        longTermThresholdDays: Int = CostBasis.defaultLongTermThresholdDays,
        feeTreatment: FeeTreatment = .ignore,
        currencyFraction: Int? = nil
    ) -> CostBasisResult {
        CostBasis.compute(events: lotEvents(for: account, asOf: asOf), method: method,
                          longTermThresholdDays: longTermThresholdDays,
                          feeTreatment: feeTreatment, currencyFraction: currencyFraction)
    }

    // MARK: Transactions

    /// Adds a transaction to the book.
    @discardableResult
    public func addTransaction(_ transaction: Transaction) -> Transaction {
        registerCommodity(transaction.currency)
        transactions.append(transaction)
        invalidateLookupIndexes()
        return transaction
    }

    /// Removes a transaction (and detaches its splits).
    public func removeTransaction(_ transaction: Transaction) {
        transactions.removeAll { $0 === transaction }
        for split in transaction.splits { split.transaction = nil }
        invalidateLookupIndexes()
    }

    // MARK: GUID lookup indexes
    //
    // `transaction(with:)` / `split(with:)` were linear scans over the whole
    // book — and the register asks per visible cell per render, which on a 46k-
    // transaction book made the UI visibly sluggish. Built lazily like the
    // price index. Splits are added/removed on their *transaction*, which the
    // book cannot observe, so a miss (or a stale hit — an indexed split that
    // has been detached) rebuilds once per generation; the app additionally
    // invalidates after every edit.
    private var transactionIndex: [GncGUID: Transaction]?
    private var splitIndex: [GncGUID: Split]?
    private var lookupRetriedAfterMiss = false

    /// Drops the GUID lookup indexes. Called by the book's own transaction
    /// add/remove, and by the app after any edit (splits can change on a
    /// transaction without the book seeing it).
    public func invalidateLookupIndexes() {
        transactionIndex = nil
        splitIndex = nil
        lookupRetriedAfterMiss = false
    }

    private func buildLookupIndexesIfNeeded() {
        guard transactionIndex == nil || splitIndex == nil else { return }
        var txns = [GncGUID: Transaction](minimumCapacity: transactions.count)
        var splits = [GncGUID: Split](minimumCapacity: transactions.count * 2)
        for transaction in transactions {
            txns[transaction.guid] = transaction
            for split in transaction.splits { splits[split.guid] = split }
        }
        transactionIndex = txns
        splitIndex = splits
    }

    /// A miss can mean "genuinely absent" or "index built before this object
    /// appeared"; one rebuild per generation tells them apart without letting a
    /// repeatedly-queried stale GUID rebuild the index every call.
    private func rebuildOnceAfterMiss() -> Bool {
        guard !lookupRetriedAfterMiss else { return false }
        lookupRetriedAfterMiss = true
        transactionIndex = nil
        splitIndex = nil
        buildLookupIndexesIfNeeded()
        return true
    }

    /// Looks up a transaction by GUID.
    public func transaction(with guid: GncGUID) -> Transaction? {
        buildLookupIndexesIfNeeded()
        if let hit = transactionIndex?[guid] { return hit }
        guard rebuildOnceAfterMiss() else { return nil }
        return transactionIndex?[guid]
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
        buildLookupIndexesIfNeeded()
        // A detached split (removed from its transaction since the index was
        // built) is stale — fall through to a rebuild.
        if let hit = splitIndex?[guid], hit.transaction != nil { return hit }
        guard rebuildOnceAfterMiss() else { return nil }
        return splitIndex?[guid]
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
            // GnuCash's cleared balance counts everything not unreconciled
            // (`NREC != reconciled`): cleared, reconciled, and frozen.
            return split.reconcileState != .notReconciled
        case .reconciled:
            // GnuCash's reconciled balance counts reconciled AND frozen
            // (`YREC == reconciled || FREC == reconciled`).
            return split.reconcileState == .reconciled || split.reconcileState == .frozen
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

    /// Every account's own balance, in one pass over the splits.
    ///
    /// ``balance(of:filter:includingDescendants:)`` walks the whole book per
    /// call, so valuing a tree of accounts one at a time is quadratic — the
    /// account tree did exactly that and cost ~28s on a 46k-transaction book.
    /// Callers that need many balances at once should ask for them together.
    /// Accounts with no postings are absent; treat a miss as zero.
    public func balancesByAccount(filter: BalanceFilter = .all,
                                  from: Date? = nil, to: Date? = nil) -> [ObjectIdentifier: Decimal] {
        var totals: [ObjectIdentifier: Decimal] = [:]
        for transaction in transactions {
            // Inclusive bounds, matching every per-account balance in the app.
            // The window is what lets a report ask for all 559 balances in one
            // walk instead of walking the book once per account — the shape
            // that made netWorthSeries 490× faster.
            if let from, transaction.datePosted < from { continue }
            if let to, transaction.datePosted > to { continue }
            for split in transaction.splits {
                guard let account = split.account, Book.matches(split, filter) else { continue }
                totals[ObjectIdentifier(account), default: 0] += split.quantity
            }
        }
        return totals
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
