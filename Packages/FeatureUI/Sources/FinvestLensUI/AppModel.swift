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
    /// GnuCash colour string (`color` slot), e.g. "rgb(144,144,238)".
    public var color: String?
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

/// A tool panel presented over the root view. Routed through
/// ``AppModel/presentedPanel`` so both menu-bar commands and toolbar buttons
/// can open any panel.
public enum RootPanel: String, Identifiable, Sendable {
    case newAccount, newTransaction, stockTransaction, currencyTransfer
    case reports, rules, scheduled, budget, prices, saveSearch, onboarding
    case reconcile
    case autoCategorize
    public var id: String { rawValue }
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
    public internal(set) var savedSearches: [SavedSearch] = []

    /// Securities tracked but not held (watch list, `FR-PLAN-07`).
    public internal(set) var watchlist: [Commodity] = []

    /// User-set price targets that raise alerts (`FR-PLAN-05`).
    public internal(set) var priceTargets: [PriceTarget] = []

    /// Per-security ticker overrides for quote lookups, keyed by
    /// `"namespace|mnemonic"` (e.g. maps `CBA` → `CBA.AX` for Yahoo).
    public internal(set) var quoteSymbols: [String: String] = [:]

    /// Progress/result of the most recent quote fetch, for the UI.
    public internal(set) var quoteStatus: QuoteFetchStatus = .idle

    /// Cost-basis method used by the capital-gains / lots reports.
    public var costBasisMethod: CostBasisMethod = .fifo

    /// Hypothetical events layered onto the cash-flow forecast (session-only).
    public internal(set) var whatIfEvents: [WhatIfEvent] = []

    /// The tool panel currently presented over the root view. Views bind a
    /// sheet to this; menu commands and toolbar buttons set it, so every panel
    /// is reachable from the menu bar as well as the toolbar.
    public var presentedPanel: RootPanel?

    /// Books opened recently (most recent first), for Open Recent / welcome.
    public private(set) var recentBooks: [URL] = AppModel.loadRecents()

    /// Set by menu commands to trigger the bank-file importer in the root view.
    public var bankImportRequested = false
    /// Set by menu commands to trigger the GnuCash XML exporter in the root view.
    public var exportRequested = false
    /// Set by menu commands to trigger the Smart Import multi-PDF picker.
    public var smartImportRequested = false

    /// A user-facing document error (open/new/import failed). When
    /// ``DocumentError/lockedURL`` is set the UI offers "Break Lock" recovery.
    public struct DocumentError: Identifiable, Sendable {
        public let id = UUID()
        public var message: String
        public var lockedURL: URL?
    }
    /// The most recent document-operation failure, surfaced as an alert.
    public var documentError: DocumentError?
    /// A user-facing confirmation (e.g. GnuCash import summary).
    public var infoMessage: String?
    /// Check & Repair findings awaiting the user's decision (sheet).
    public var pendingCleanup: CleanupProposal?

    /// API-key store (Keychain in production; injectable for tests/previews).
    let apiKeys: APIKeyStoring
    /// HTTP transport for quote providers (injectable for tests).
    let quoteHTTP: HTTPFetching
    /// Device authentication for the book lock (injectable for tests).
    let authenticator: Authenticating

    /// The running periodic quote-refresh loop, if any.
    @ObservationIgnored var quoteRefreshTask: Task<Void, Never>?

    /// Refreshes the lock heartbeat while a book is open, so a live holder's
    /// lock never looks stale to another instance (Architecture §6.1).
    @ObservationIgnored var heartbeatTask: Task<Void, Never>?

    /// Periodically saves unsaved changes back to the shared file
    /// (Architecture §3/§6.2 autosave; failures surface via ``documentError``).
    @ObservationIgnored var autosaveTask: Task<Void, Never>?

    /// `true` when the open book is locked behind authentication (`NFR-07`).
    public internal(set) var isLocked = false

    /// `true` when the shared file changed externally (another device via
    /// iCloud) since we opened it (`FR-PLT-02`).
    public internal(set) var externalChangePending = false

    /// `true` when a document is open.
    public var isOpen: Bool { document != nil }
    /// The open document's file URL (window title / titlebar proxy icon).
    public var documentURL: URL? { document?.fileURL }
    /// `true` when there are unsaved changes.
    public var hasUnsavedChanges: Bool { document?.hasUnsavedChanges ?? false }

    var book: Book? { document?.book }

    public init(apiKeys: APIKeyStoring? = nil, quoteHTTP: HTTPFetching? = nil,
                authenticator: Authenticating? = nil) {
        self.apiKeys = apiKeys ?? KeychainAPIKeyStore()
        self.quoteHTTP = quoteHTTP ?? URLSessionHTTPClient()
        self.authenticator = authenticator ?? BiometricAuthenticator()
    }

    // MARK: KVP-backed collections

    private enum KvpKey {
        static let rules = "finvestlens/ruleGroups"
        static let scheduled = "finvestlens/scheduledTransactions"
        static let budgets = "finvestlens/budgets"
        static let quoteSymbols = "finvestlens/quoteSymbols"
        static let savedSearches = "finvestlens/savedSearches"
        static let watchlist = "finvestlens/watchlist"
        static let priceTargets = "finvestlens/priceTargets"
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
        savedSearches = Self.decodeSlot([SavedSearch].self, book.kvp[KvpKey.savedSearches]) ?? []
        watchlist = Self.decodeSlot([Commodity].self, book.kvp[KvpKey.watchlist]) ?? []
        priceTargets = Self.decodeSlot([PriceTarget].self, book.kvp[KvpKey.priceTargets]) ?? []
    }

    /// Writes the KVP-backed collections into the current book's slots.
    func persistKvpCollections() {
        guard let book else { return }
        book.kvp[KvpKey.rules] = Self.encodeSlot(ruleGroups)
        book.kvp[KvpKey.scheduled] = Self.encodeSlot(scheduledTransactions)
        book.kvp[KvpKey.budgets] = Self.encodeSlot(budgets)
        book.kvp[KvpKey.quoteSymbols] = Self.encodeMap(quoteSymbols)
        book.kvp[KvpKey.savedSearches] = Self.encodeSlot(savedSearches)
        book.kvp[KvpKey.watchlist] = Self.encodeSlot(watchlist)
        book.kvp[KvpKey.priceTargets] = Self.encodeSlot(priceTargets)
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
        startQuoteAutoRefresh()
        recordLastBook(url)
        resetUndoBaseline()
    }

    public func open(at url: URL, breakStaleLock: Bool = false) throws {
        // Books picked via the iOS document picker (iCloud Drive, Box,
        // Dropbox, …) are security-scoped; access must span the whole session
        // because saves write back to the shared file.
        let accessURL = beginBookAccess(to: url)
        do {
            document = try FinvestLensDocument.open(at: accessURL,
                                                    breakStaleLock: breakStaleLock)
        } catch {
            endBookAccess()
            throw error
        }
        reloadKvpCollections()
        refreshAll()
        startQuoteAutoRefresh()
        lockIfNeeded()
        recordLastBook(accessURL)
        observeExternalChanges()
        resetUndoBaseline()
    }

    // MARK: Security-scoped access (iOS document-provider locations)

    private var scopedBookURL: URL?
    private static let recentBookmarksKey = "finvestlens.recentBookBookmarks"

    /// Starts security-scoped access to a book and keeps it for the session.
    /// Picker URLs carry their own scope; recents resolve through the stored
    /// bookmark (which can rewrite the path, so the caller must open the
    /// returned URL). On unsandboxed macOS both attempts are no-ops and the
    /// URL is returned unchanged.
    private func beginBookAccess(to url: URL) -> URL {
        endBookAccess()
        if url.startAccessingSecurityScopedResource() {
            scopedBookURL = url
            return url
        }
        if let resolved = Self.resolveBookmark(forPath: url.path),
           resolved.startAccessingSecurityScopedResource() {
            scopedBookURL = resolved
            return resolved
        }
        return url
    }

    private func endBookAccess() {
        scopedBookURL?.stopAccessingSecurityScopedResource()
        scopedBookURL = nil
    }

    private static func resolveBookmark(forPath path: String) -> URL? {
        guard let bookmarks = UserDefaults.standard
                .dictionary(forKey: recentBookmarksKey) as? [String: Data],
              let data = bookmarks[path] else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }

    /// Keeps the advisory lock alive and autosaves while a book is open.
    /// Without the heartbeat, an idle book's lock ages past the staleness
    /// window and another instance could legitimately break it — two writers.
    private func startDocumentMaintenance() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { break }
                self?.document?.heartbeat()
            }
        }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, let self, self.hasUnsavedChanges else { continue }
                do {
                    try self.save()
                } catch {
                    // Surface once; don't stack alerts every interval.
                    if self.documentError == nil {
                        self.documentError = DocumentError(
                            message: "Autosave failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func stopDocumentMaintenance() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        autosaveTask?.cancel(); autosaveTask = nil
    }

    /// Watches the shared file for external changes (iCloud sync from another
    /// device) and raises ``externalChangePending`` (`FR-PLT-02`).
    private func observeExternalChanges() {
        document?.startObservingExternalChanges { [weak self] in
            Task { @MainActor in
                guard let self, let document = self.document else { return }
                if document.hasExternalChanges() { self.externalChangePending = true }
            }
        }
    }

    /// Reloads the book from the shared file, adopting external changes and
    /// discarding unsaved local edits.
    public func reloadFromDisk() {
        guard let document else { return }
        try? document.reloadFromDisk()
        externalChangePending = false
        reloadKvpCollections()
        refreshAll()
    }

    // MARK: Version conflicts (iCloud "edited in two places")

    /// `true` when the shared file has unresolved NSFileVersion conflicts.
    public var hasVersionConflicts: Bool {
        !(document?.unresolvedConflictVersions().isEmpty ?? true)
    }

    /// Keeps the local version: marks all conflict versions resolved and
    /// re-saves our copy over the shared file. Failures surface — the user
    /// must not believe their version won when it didn't.
    public func resolveConflictsKeepingMine() {
        guard let document else { return }
        do {
            try document.resolveConflictsKeepingCurrent()
            try document.save()
            externalChangePending = false
        } catch {
            documentError = DocumentError(
                message: "Couldn’t keep your version: \(error.localizedDescription)")
        }
        refreshAll()
    }

    /// Adopts the most recent conflicting version and reloads from it.
    public func resolveConflictsUsingOther() {
        guard let document else { return }
        let versions = document.unresolvedConflictVersions()
        if let newest = versions.max(by: {
            ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast)
        }) {
            try? document.adoptConflictVersion(newest)
        }
        reloadFromDisk()
    }

    /// Remembers the last-opened book so App Intents / Shortcuts can read it,
    /// and maintains the recents list (most recent first, capped at 5).
    func recordLastBook(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "finvestlens.lastBookPath")
        var paths = UserDefaults.standard.stringArray(forKey: "finvestlens.recentBookPaths") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        paths = Array(paths.prefix(5))
        UserDefaults.standard.set(paths, forKey: "finvestlens.recentBookPaths")
        recentBooks = paths.map { URL(fileURLWithPath: $0) }

        // Bookmark taken while scoped access is active, so Open Recent can
        // regain the grant on iOS after a relaunch. Pruned with the list.
        var bookmarks = UserDefaults.standard
            .dictionary(forKey: Self.recentBookmarksKey) as? [String: Data] ?? [:]
        if let bookmark = try? url.bookmarkData() {
            bookmarks[url.path] = bookmark
        }
        bookmarks = bookmarks.filter { paths.contains($0.key) }
        UserDefaults.standard.set(bookmarks, forKey: Self.recentBookmarksKey)
    }

    static func loadRecents() -> [URL] {
        // A provider-backed book (iCloud/Box/Dropbox on iOS) isn't visible to
        // fileExists without its grant — keep it if we hold a bookmark for it.
        let bookmarks = UserDefaults.standard
            .dictionary(forKey: recentBookmarksKey) as? [String: Data] ?? [:]
        return (UserDefaults.standard.stringArray(forKey: "finvestlens.recentBookPaths") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) || bookmarks[$0.path] != nil }
    }

    /// `true` when `error` means the book is locked by another instance —
    /// offer "Break Lock" recovery (safe when the other instance crashed).
    public static func isLockedError(_ error: Error) -> Bool {
        if case FileLock.LockError.alreadyLocked = error { return true }
        return false
    }

    // MARK: Safe document operations (error-surfacing wrappers)

    /// Saves any open book, then opens `url`; failures land in
    /// ``documentError`` (with Break-Lock recovery for stale locks).
    public func openBook(at url: URL, breakStaleLock: Bool = false) {
        guard saveAndCloseIfOpen() else { return }
        do {
            try open(at: url, breakStaleLock: breakStaleLock)
        } catch {
            documentError = DocumentError(
                message: Self.isLockedError(error)
                    ? "“\(url.lastPathComponent)” is locked by another FinvestLens instance. If that instance crashed, you can break the lock and open anyway."
                    : error.localizedDescription,
                lockedURL: Self.isLockedError(error) ? url : nil)
        }
    }

    /// Saves any open book, then creates a new one at `url`.
    public func newBook(at url: URL, baseCurrency: Commodity = .aud) {
        guard saveAndCloseIfOpen() else { return }
        do {
            try newDocument(at: url, baseCurrency: baseCurrency)
        } catch {
            documentError = DocumentError(message: error.localizedDescription)
        }
    }

    /// Imports a GnuCash XML file as a new native book, reporting the summary
    /// (or the failure) through ``infoMessage`` / ``documentError``.
    public func importGnuCashBook(from source: URL, saveAs destination: URL) {
        guard saveAndCloseIfOpen() else { return }
        do {
            let summary = try importGnuCash(from: source, saveAs: destination)
            recordLastBook(destination)
            let note = "Imported \(summary.accountCount) accounts and \(summary.transactionCount) transactions from “\(source.lastPathComponent)”."
            // Offer Check & Repair when the imported book has issues
            // (empty stubs, orphans, imbalances) — GnuCash files often do.
            if let proposal = cleanupProposal(importNote: note) {
                pendingCleanup = proposal
            } else {
                infoMessage = note
            }
        } catch {
            documentError = DocumentError(message: "Couldn’t import “\(source.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    /// Saves and closes the current book, if any — switching books never
    /// silently discards work. Returns `false` (leaving the book open and
    /// surfacing ``documentError``) if the save failed; callers must not
    /// proceed with whatever would have replaced the book.
    @discardableResult
    public func saveAndCloseIfOpen() -> Bool {
        guard isOpen else { return true }
        if hasUnsavedChanges {
            do {
                try save()
            } catch {
                documentError = DocumentError(
                    message: "Couldn’t save “\(documentURL?.lastPathComponent ?? "book")”: \(error.localizedDescription)")
                return false
            }
        }
        close()
        return true
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
        startQuoteAutoRefresh()
        startDocumentMaintenance()
        observeExternalChanges()
        resetUndoBaseline()
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
        stopQuoteAutoRefresh()
        document?.stopObservingExternalChanges()
        isLocked = false
        externalChangePending = false
        presentedPanel = nil
        searchQuery = ""
        document?.discard()
        document = nil
        endBookAccess()
        accountTree = []
        registerRows = []
        selectedAccountID = nil
        ruleGroups = []
        scheduledTransactions = []
        budgets = []
        savedSearches = []
        watchlist = []
        priceTargets = []
        quoteSymbols = [:]
        quoteStatus = .idle
        whatIfEvents = []
        resetUndoBaseline()
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
        registerUndoSnapshot()
    }

    // MARK: Undo / redo (HIG: every edit must be undoable)
    //
    // Snapshot-based: after every mutation the previous whole-book state (as
    // GnuCash XML, which round-trips all data including KVP slots) is pushed
    // onto the window's UndoManager. Undoing swaps the snapshot back in; the
    // swap itself funnels through `markDirtyAndRefresh`, which is what makes
    // redo work.

    /// The focused window's undo manager, injected by the root view.
    @ObservationIgnored public weak var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = 25 }
    }
    /// The book state after the previous mutation (== before the next one).
    @ObservationIgnored var lastUndoSnapshot: Data?

    /// Called from `markDirtyAndRefresh` after each mutation.
    private func registerUndoSnapshot() {
        guard isOpen else { return }
        let previous = lastUndoSnapshot
        lastUndoSnapshot = gnuCashExportData()
        guard let previous, previous != lastUndoSnapshot else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            model.restoreSnapshot(previous)
        }
        if undoManager?.isUndoing != true && undoManager?.isRedoing != true {
            undoManager?.setActionName("Change")
        }
    }

    /// Resets the undo baseline (call when a book is opened/created/closed).
    func resetUndoBaseline() {
        undoManager?.removeAllActions(withTarget: self)
        lastUndoSnapshot = isOpen ? gnuCashExportData() : nil
    }

    /// Restores a whole-book snapshot (the undo/redo primitive).
    func restoreSnapshot(_ data: Data) {
        guard let document,
              let result = try? GnuCashXMLImporter.importBook(from: data) else { return }
        document.replaceBook(result.book)
        reloadKvpCollections()
        markDirtyAndRefresh()
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
            color: account.color,
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
        // Swap the imported book in wholesale. A piecemeal copy of only
        // commodities/accounts/transactions silently dropped the price
        // database, book-level KVP slots, and the imported book GUID —
        // losing 100k+ prices from a real GnuCash import.
        doc.replaceBook(book)
        try doc.save()
    }
}
