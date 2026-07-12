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

    public var selectedAccountID: GncGUID? {
        didSet { refreshRegister() }
    }

    /// `true` when a document is open.
    public var isOpen: Bool { document != nil }
    /// `true` when there are unsaved changes.
    public var hasUnsavedChanges: Bool { document?.hasUnsavedChanges ?? false }

    private var book: Book? { document?.book }

    public init() {}

    // MARK: Document lifecycle

    public func newDocument(at url: URL, baseCurrency: Commodity = .aud) throws {
        document = try FinvestLensDocument.create(at: url, baseCurrency: baseCurrency)
        refreshAll()
    }

    public func open(at url: URL, breakStaleLock: Bool = false) throws {
        document = try FinvestLensDocument.open(at: url, breakStaleLock: breakStaleLock)
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
        refreshAll()
        return result.summary
    }

    public func save() throws {
        try document?.save()
        refreshAll()
    }

    public func revert() throws {
        try document?.revert()
        refreshAll()
    }

    public func close() {
        document?.discard()
        document = nil
        accountTree = []
        registerRows = []
        selectedAccountID = nil
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

    private func refreshAll() {
        rebuildAccountTree()
        refreshRegister()
    }

    private func markDirtyAndRefresh() {
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
