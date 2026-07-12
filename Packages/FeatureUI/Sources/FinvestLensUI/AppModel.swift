//
//  AppModel.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import FinvestLensEngine
import FinvestLensPersistence
import FinvestLensInterchange
import FinvestLensRules
import FinvestLensQuotes
import FinvestLensReports

/// A row in the chart-of-accounts tree.
public struct AccountNode: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var name: String
    public var fullName: String
    public var typeName: String
    public var balance: Decimal
    public var currencyCode: String
    public var isPlaceholder: Bool
    public var isHidden: Bool
    public var children: [AccountNode]?
}

/// A row in an account register (one split, with a running balance).
public struct RegisterRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var date: Date
    public var number: String
    public var description: String
    public var transfer: String
    public var reconcile: String
    public var amount: Decimal
    public var runningBalance: Decimal
}

/// The observable application/document model driving the UI.
///
/// The engine ``Book`` is the source of truth but is not itself observable, so
/// `AppModel` recomputes plain value snapshots (``accountTree``,
/// ``registerRows``) after each mutation — SwiftUI observes those. Document
/// operations delegate to ``FinvestLensPersistence``.
@MainActor
@Observable
public final class AppModel {

    public private(set) var document: FinvestLensDocument?
    public private(set) var accountTree: [AccountNode] = []
    public private(set) var registerRows: [RegisterRow] = []
    public private(set) var priceRows: [PriceRow] = []
    public private(set) var rateRows: [RateRow] = []

    public var selectedAccountID: GncGUID? {
        didSet { refreshRegister() }
    }

    /// Free-text query; setting it recomputes ``searchResults``.
    public var searchQuery: String = "" {
        didSet { runSearch() }
    }
    public internal(set) var searchResults: [TransactionSummary] = []

    /// The active reconciliation session, or `nil` when not reconciling.
    public internal(set) var reconcileSession: ReconcileSessionState?

    // Book-KVP-backed collections, held as observed stored properties so views
    // update when they change (the underlying `book.kvp` is not observable).
    // Loaded from the book on open and persisted back on mutation.
    public internal(set) var ruleGroups: [RuleGroup] = []
    public internal(set) var scheduledTransactions: [ScheduledTransaction] = []
    public internal(set) var budgets: [Budget] = []

    /// Per-security ticker overrides for quote lookups, keyed by
    /// `"namespace|mnemonic"` (e.g. maps `CBA` → `CBA.AX` for Yahoo).
    public internal(set) var quoteSymbols: [String: String] = [:]

    /// Progress/result of the most recent quote fetch, for the UI.
    public internal(set) var quoteStatus: QuoteFetchStatus = .idle

    /// Cost-basis method used by the capital-gains / lots reports.
    public var costBasisMethod: CostBasisMethod = .fifo

    /// Hypothetical events layered onto the cash-flow forecast (session-only).
    public internal(set) var whatIfEvents: [WhatIfEvent] = []

    /// API-key store (Keychain in production; injectable for tests/previews).
    let apiKeys: APIKeyStoring
    /// HTTP transport for quote providers (injectable for tests).
    let quoteHTTP: HTTPFetching

    /// `true` when a document is open.
    public var isOpen: Bool { document != nil }
    /// `true` when there are unsaved changes.
    public var hasUnsavedChanges: Bool { document?.hasUnsavedChanges ?? false }

    var book: Book? { document?.book }

    public init(apiKeys: APIKeyStoring? = nil, quoteHTTP: HTTPFetching? = nil) {
        self.apiKeys = apiKeys ?? KeychainAPIKeyStore()
        self.quoteHTTP = quoteHTTP ?? URLSessionHTTPClient()
    }

    // MARK: KVP-backed collections

    private enum KvpKey {
        static let rules = "finvestlens/ruleGroups"
        static let scheduled = "finvestlens/scheduledTransactions"
        static let budgets = "finvestlens/budgets"
        static let quoteSymbols = "finvestlens/quoteSymbols"
    }

    /// Loads the KVP-backed collections from the current book.
    func reloadKvpCollections() {
        guard let book else {
            ruleGroups = []; scheduledTransactions = []; budgets = []; quoteSymbols = [:]
            return
        }
        ruleGroups = Self.decodeSlot([RuleGroup].self, book.kvp[KvpKey.rules]) ?? []
        scheduledTransactions = Self.decodeSlot([ScheduledTransaction].self, book.kvp[KvpKey.scheduled]) ?? []
        budgets = Self.decodeSlot([Budget].self, book.kvp[KvpKey.budgets]) ?? []
        quoteSymbols = Self.decodeSlot([String: String].self, book.kvp[KvpKey.quoteSymbols]) ?? [:]
    }

    /// Writes the KVP-backed collections into the current book's slots.
    func persistKvpCollections() {
        guard let book else { return }
        book.kvp[KvpKey.rules] = Self.encodeSlot(ruleGroups)
        book.kvp[KvpKey.scheduled] = Self.encodeSlot(scheduledTransactions)
        book.kvp[KvpKey.budgets] = Self.encodeSlot(budgets)
        book.kvp[KvpKey.quoteSymbols] = Self.encodeMap(quoteSymbols)
    }

    /// Persists the collections and refreshes derived UI state.
    func commitKvpCollections() {
        persistKvpCollections()
        markDirtyAndRefresh()
    }

    private static func decodeSlot<T: Decodable>(_ type: T.Type, _ value: KvpValue?) -> T? {
        guard case let .string(json)? = value, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encodeSlot<T: Encodable>(_ array: [T]) -> KvpValue? {
        guard !array.isEmpty,
              let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return .string(json)
    }

    private static func encodeMap(_ map: [String: String]) -> KvpValue? {
        guard !map.isEmpty,
              let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return .string(json)
    }

    // MARK: Document lifecycle

    public func newDocument(at url: URL, baseCurrency: Commodity = .aud) throws {
        document = try FinvestLensDocument.create(at: url, baseCurrency: baseCurrency)
        reloadKvpCollections()
        refreshAll()
    }

    public func open(at url: URL, breakStaleLock: Bool = false) throws {
        document = try FinvestLensDocument.open(at: url, breakStaleLock: breakStaleLock)
        reloadKvpCollections()
        refreshAll()
    }

    /// Imports a GnuCash file and saves it as a new native document.
    @discardableResult
    public func importGnuCash(from source: URL, saveAs destination: URL) throws -> ImportSummary {
        let result = try GnuCashXMLImporter.importBook(from: source)
        let doc = try FinvestLensDocument.create(at: destination,
                                                 baseCurrency: result.book.commodities.first ?? .aud)
        // Replace the fresh document's book with the imported one and save.
        try replaceBook(of: doc, with: result.book)
        document = doc
        reloadKvpCollections()
        refreshAll()
        return result.summary
    }

    /// Serialises the current book to GnuCash XML (`FR-EXP-01`), optionally
    /// gzip-compressed. Returns `nil` if no document is open.
    public func gnuCashExportData(compressed: Bool = false) -> Data? {
        guard let book else { return nil }
        return GnuCashXMLExporter.export(book, compressed: compressed)
    }

    public func save() throws {
        try document?.save()
        refreshAll()
    }

    public func revert() throws {
        try document?.revert()
        reloadKvpCollections()
        refreshAll()
    }

    public func close() {
        document?.discard()
        document = nil
        accountTree = []
        registerRows = []
        selectedAccountID = nil
        ruleGroups = []
        scheduledTransactions = []
        budgets = []
        quoteSymbols = [:]
        quoteStatus = .idle
        whatIfEvents = []
    }

    // MARK: Mutations

    @discardableResult
    public func addAccount(name: String, type: AccountType, commodity: Commodity? = nil,
                           parentID: GncGUID? = nil) -> GncGUID? {
        guard let book else { return nil }
        let parent = parentID.flatMap { book.account(with: $0) } ?? book.rootAccount
        let account = Account(name: name, type: type, commodity: commodity ?? parent.commodity)
        book.addAccount(account, under: parent)
        markDirtyAndRefresh()
        return account.guid
    }

    /// Whether an account can be deleted (no postings and no children).
    public func canDeleteAccount(_ id: GncGUID) -> Bool {
        guard let book, let account = book.account(with: id) else { return false }
        return account.children.isEmpty && book.splits(for: account).isEmpty
    }

    public func deleteAccount(_ id: GncGUID) {
        guard let book, let account = book.account(with: id), canDeleteAccount(id) else { return }
        account.parent?.removeChild(account)
        if selectedAccountID == id { selectedAccountID = nil }
        markDirtyAndRefresh()
    }

    public func renameAccount(_ id: GncGUID, to newName: String) {
        guard let book, let account = book.account(with: id) else { return }
        account.name = newName
        markDirtyAndRefresh()
    }

    /// Assigns sequential codes to the children of `parentID` (or the top level),
    /// ordered by existing code then name (`FR-COA`). Codes are zero-padded,
    /// e.g. prefix "" interval 10 → "010", "020", … `nil` parent renumbers the
    /// top-level accounts.
    public func renumberChildren(of parentID: GncGUID?, prefix: String = "", interval: Int = 10) {
        guard let book else { return }
        let parent = parentID.flatMap { book.account(with: $0) } ?? book.rootAccount
        let children = parent.children.sorted {
            ($0.code, $0.name) < ($1.code, $1.name)
        }
        guard !children.isEmpty else { return }
        let width = String((children.count) * max(interval, 1)).count
        for (index, child) in children.enumerated() {
            let number = (index + 1) * max(interval, 1)
            child.code = prefix + String(format: "%0\(width)d", number)
        }
        markDirtyAndRefresh()
    }

    /// Records a simple two-account transaction moving `amount` from `sourceID`
    /// into `destinationID` (positive `amount` credits the destination).
    @discardableResult
    public func addTransfer(from sourceID: GncGUID, to destinationID: GncGUID,
                            amount: Decimal, date: Date, description: String) -> GncGUID? {
        guard let book,
              let source = book.account(with: sourceID),
              let destination = book.account(with: destinationID)
        else { return nil }
        let txn = Transaction(currency: destination.commodity, datePosted: date, description: description)
        txn.addSplit(account: destination, value: amount)
        txn.addSplit(account: source, value: -amount)
        book.addTransaction(txn)
        markDirtyAndRefresh()
        return txn.guid
    }

    // MARK: Snapshots

    func refreshAll() {
        rebuildAccountTree()
        refreshRegister()
        rebuildPrices()
        runSearch()
    }

    private func rebuildPrices() {
        guard let book else { priceRows = []; rateRows = []; return }
        let sorted = book.prices.sorted { $0.date > $1.date }
        priceRows = sorted
            .filter { $0.commodity.namespace != .currency }
            .map { PriceRow(id: $0.guid, symbol: $0.commodity.mnemonic,
                            currencyCode: $0.currency.mnemonic, date: $0.date, value: $0.value) }
        rateRows = sorted
            .filter { $0.commodity.namespace == .currency }
            .map { RateRow(id: $0.guid, from: $0.commodity.mnemonic,
                           to: $0.currency.mnemonic, date: $0.date, value: $0.value) }
    }

    func markDirtyAndRefresh() {
        document?.markDirty()
        refreshAll()
    }

    private func rebuildAccountTree() {
        guard let book else { accountTree = []; return }
        accountTree = book.rootAccount.children.map { node(for: $0, book: book) }
    }

    private func node(for account: Account, book: Book) -> AccountNode {
        let children = account.children.map { node(for: $0, book: book) }
        return AccountNode(
            id: account.guid,
            name: account.name,
            fullName: account.fullName,
            typeName: account.type.rawValue.capitalized,
            balance: book.balance(of: account, includingDescendants: true).rounded.amount,
            currencyCode: account.commodity.mnemonic,
            isPlaceholder: account.isPlaceholder,
            isHidden: account.isHidden,
            children: children.isEmpty ? nil : children
        )
    }

    private func refreshRegister() {
        guard let book, let id = selectedAccountID, let account = book.account(with: id) else {
            registerRows = []
            return
        }
        let splits = book.splits(for: account).sorted {
            ($0.transaction?.datePosted ?? .distantPast) < ($1.transaction?.datePosted ?? .distantPast)
        }
        var running = Decimal(0)
        registerRows = splits.map { split in
            running += split.quantity
            return RegisterRow(
                id: split.guid,
                date: split.transaction?.datePosted ?? Date(timeIntervalSince1970: 0),
                number: split.transaction?.number ?? "",
                description: split.transaction?.transactionDescription ?? "",
                transfer: transferDescription(for: split, in: account),
                reconcile: split.reconcileState.rawValue,
                amount: split.quantity,
                runningBalance: running
            )
        }
    }

    private func transferDescription(for split: Split, in account: Account) -> String {
        guard let others = split.transaction?.splits.filter({ $0 !== split }) else { return "" }
        let names = others.compactMap { $0.account?.name }
        if names.count == 1 { return names[0] }
        if names.count > 1 { return "— Split —" }
        return ""
    }

    // MARK: Helpers

    private func replaceBook(of doc: FinvestLensDocument, with book: Book) throws {
        // Copy accounts and transactions from `book` into the document's book.
        let target = doc.book
        for commodity in book.commodities { target.registerCommodity(commodity) }
        for child in book.rootAccount.children { target.rootAccount.addChild(child) }
        for txn in book.transactions { target.addTransaction(txn) }
        doc.markDirty()
        try doc.save()
    }
}
