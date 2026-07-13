//
//  GnuCashXMLImporter.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Imports a GnuCash XML file (compressed or not) into an engine ``Book``.
///
/// A streaming `XMLParser` (SAX) reads the GnuCash v2 namespaces and maps
/// commodities, the account hierarchy, and transactions/splits, preserving
/// GUIDs (Architecture ADR-2/ADR-3). Amounts are GnuCash rationals (`num/denom`)
/// converted to `Decimal`. After parsing, `Scrub` validates the result
/// (`FR-IMP-08`). Prices **are** mapped (`FR-IMP-02`); GnuCash-native budget,
/// scheduled-transaction (`sx:`) and business objects are not yet mapped and
/// are counted as warnings (FinvestLens keeps its own in KVP slots).
///
/// Slot (KVP) handling in P1 is intentionally minimal: the account
/// `placeholder`/`hidden` flags are read; richer slot preservation for full
/// round-trip fidelity is a P3 concern.
public enum GnuCashXMLImporter {

    /// Imports from raw file `data`, transparently decompressing gzip.
    public static func importBook(from data: Data) throws -> ImportResult {
        guard !data.isEmpty else { throw ImportError.emptyData }
        let xml = try Gzip.decompressIfNeeded(data)

        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = false
        let delegate = Delegate()
        parser.delegate = delegate

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription
                ?? "line \(parser.lineNumber)"
            throw ImportError.malformedXML(message)
        }

        return try delegate.assemble()
    }

    /// Imports from a file URL.
    public static func importBook(from url: URL) throws -> ImportResult {
        try importBook(from: Data(contentsOf: url))
    }
}

// MARK: - SAX delegate

private final class Delegate: NSObject, XMLParserDelegate {

    // Parsed collections.
    private var commoditiesByKey: [String: Commodity] = [:]
    private var commodityOrder: [String] = []
    private var accountsByGUID: [GncGUID: Account] = [:]
    private var accountOrder: [GncGUID] = []
    private var parentGUID: [GncGUID: GncGUID] = [:]
    private var rootGUID: GncGUID?
    private var transactions: [Transaction] = []
    private var prices: [Price] = []
    private var summary = ImportSummary()

    // Parse state.
    private var stack: [String] = []
    private var text = ""

    // Builders for the object currently being read.
    private var commodity: CommodityBuilder?
    private var account: AccountBuilder?
    private var transaction: TransactionBuilder?
    private var split: SplitBuilder?
    private var price: PriceBuilder?
    private var slotKey: String?

    private var parentElement: String? { stack.count >= 2 ? stack[stack.count - 2] : nil }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        stack.append(name)
        text = ""

        switch name {
        case "gnc:commodity": commodity = CommodityBuilder()
        case "gnc:account": account = AccountBuilder()
        case "gnc:transaction": transaction = TransactionBuilder()
        case "trn:split": split = SplitBuilder()
        case "price": price = PriceBuilder(); summary.priceCount += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if stack.last == name { stack.removeLast() }
            text = ""
        }

        switch name {
        // Commodity fields (context: definition vs. reference).
        case "cmdty:space": setCommodityField(space: value)
        case "cmdty:id": setCommodityField(id: value)
        case "cmdty:name": commodity?.name = value
        case "cmdty:fraction": commodity?.fraction = Int(value)
        case "gnc:commodity": finishCommodityDefinition()

        // Account fields.
        case "act:name": account?.name = value
        case "act:id": account?.guid = GncGUID(hex: value)
        case "act:type": account?.type = value
        case "act:code": account?.code = value
        case "act:description": account?.descriptionText = value
        case "act:commodity-scu": account?.scu = Int(value)
        case "act:parent": account?.parentGUID = GncGUID(hex: value)
        case "gnc:account": finishAccount()

        // Transaction fields.
        case "trn:id": transaction?.guid = GncGUID(hex: value)
        case "trn:description": transaction?.descriptionText = value
        case "trn:num": transaction?.number = value
        case "ts:date": setTransactionDate(value)
        case "gnc:transaction": finishTransaction()

        // Price fields.
        case "price:id": price?.guid = GncGUID(hex: value)
        case "price:source": price?.source = value
        case "price:type": price?.type = value
        case "price:value": price?.value = GnuCashNumeric.parse(value)
        case "price": finishPrice()

        // Split fields.
        case "split:id": split?.guid = GncGUID(hex: value)
        case "split:reconciled-state": split?.reconcileState = value
        case "split:value": split?.value = GnuCashNumeric.parse(value)
        case "split:quantity": split?.quantity = GnuCashNumeric.parse(value)
        case "split:account": split?.accountGUID = GncGUID(hex: value)
        case "split:memo": split?.memo = value
        case "split:action": split?.action = value
        case "trn:split": finishSplit()

        // Minimal slot handling (account placeholder/hidden).
        case "slot:key": slotKey = value
        case "slot:value": applySlot(value)

        default: break
        }
    }

    // MARK: Context-sensitive commodity fields

    private func setCommodityField(space: String? = nil, id: String? = nil) {
        switch parentElement {
        case "gnc:commodity":
            if let space { commodity?.space = space }
            if let id { commodity?.id = id }
        case "act:commodity":
            if let space { account?.commoditySpace = space }
            if let id { account?.commodityID = id }
        case "trn:currency":
            if let space { transaction?.currencySpace = space }
            if let id { transaction?.currencyID = id }
        case "price:commodity":
            if let space { price?.commoditySpace = space }
            if let id { price?.commodityID = id }
        case "price:currency":
            if let space { price?.currencySpace = space }
            if let id { price?.currencyID = id }
        default:
            break
        }
    }

    private func setTransactionDate(_ raw: String) {
        guard let date = GnuCashDate.parse(raw) else { return }
        switch parentElement {
        case "trn:date-posted": transaction?.datePosted = date
        case "trn:date-entered": transaction?.dateEntered = date
        case "price:time": price?.date = date
        default: break
        }
    }

    private func applySlot(_ value: String) {
        guard let key = slotKey, account != nil else { slotKey = nil; return }
        switch key {
        case "placeholder": account?.isPlaceholder = (value == "true")
        case "hidden": account?.isHidden = (value == "true")
        default: break
        }
        slotKey = nil
    }

    // MARK: Finishers

    private func finishCommodityDefinition() {
        defer { commodity = nil }
        guard let builder = commodity, let space = builder.space, let id = builder.id else { return }
        let commodityValue = builder.makeCommodity()
        let key = Self.commodityKey(space: space, id: id)
        if commoditiesByKey[key] == nil {
            commodityOrder.append(key)
        }
        commoditiesByKey[key] = commodityValue
    }

    private func finishAccount() {
        defer { account = nil }
        guard let builder = account, let guid = builder.guid else {
            summary.warnings.append("Skipped an account with no GUID")
            return
        }
        let commodity = resolveCommodity(space: builder.commoditySpace, id: builder.commodityID,
                                         fractionHint: builder.scu)
        let type = AccountType(rawValue: builder.type ?? "") ?? {
            summary.warnings.append("Unknown account type '\(builder.type ?? "")' for '\(builder.name)'")
            return .asset
        }()

        let acct = Account(
            guid: guid,
            name: builder.name,
            type: type,
            commodity: commodity,
            code: builder.code,
            description: builder.descriptionText,
            isPlaceholder: builder.isPlaceholder,
            isHidden: builder.isHidden
        )
        accountsByGUID[guid] = acct
        accountOrder.append(guid)
        if type == .root {
            rootGUID = guid
        } else if let parent = builder.parentGUID {
            parentGUID[guid] = parent
        }
    }

    private func finishSplit() {
        defer { split = nil }
        guard let builder = split, transaction != nil else { return }
        let engineSplit = Split(
            guid: builder.guid ?? .random(),
            account: builder.accountGUID.flatMap { accountsByGUID[$0] },
            value: builder.value ?? 0,
            quantity: builder.quantity ?? builder.value ?? 0,
            reconcileState: ReconcileState(rawValue: builder.reconcileState ?? "n") ?? .notReconciled,
            memo: builder.memo,
            action: builder.action
        )
        transaction?.pendingSplits.append(engineSplit)
    }

    private func finishTransaction() {
        defer { transaction = nil }
        guard let builder = transaction, let guid = builder.guid else {
            summary.warnings.append("Skipped a transaction with no GUID")
            return
        }
        let currency = resolveCommodity(space: builder.currencySpace, id: builder.currencyID,
                                        fractionHint: nil)
        let txn = Transaction(
            guid: guid,
            currency: currency,
            datePosted: builder.datePosted ?? Date(timeIntervalSince1970: 0),
            dateEntered: builder.dateEntered,
            number: builder.number,
            description: builder.descriptionText
        )
        for split in builder.pendingSplits { txn.addSplit(split) }
        transactions.append(txn)
    }

    private func finishPrice() {
        defer { price = nil }
        guard let builder = price, let value = builder.value else { return }
        let commodity = resolveCommodity(space: builder.commoditySpace, id: builder.commodityID, fractionHint: nil)
        let currency = resolveCommodity(space: builder.currencySpace, id: builder.currencyID, fractionHint: nil)
        prices.append(Price(
            guid: builder.guid ?? .random(),
            commodity: commodity,
            currency: currency,
            date: builder.date ?? Date(timeIntervalSince1970: 0),
            value: value,
            source: builder.source,
            type: builder.type
        ))
    }

    // MARK: Commodity resolution

    private static func commodityKey(space: String, id: String) -> String { "\(space)|\(id)" }

    private func resolveCommodity(space: String?, id: String?, fractionHint: Int?) -> Commodity {
        guard let space, let id else {
            summary.warnings.append("Missing commodity reference; defaulted to AUD")
            return .aud
        }
        let key = Self.commodityKey(space: space, id: id)
        if let existing = commoditiesByKey[key] { return existing }

        // Synthesise a commodity not declared in the file.
        let namespace: CommodityNamespace = (space == "CURRENCY") ? .currency : .security(space)
        let synthesized = Commodity(
            namespace: namespace,
            mnemonic: id,
            fullName: id,
            smallestFraction: fractionHint ?? (space == "CURRENCY" ? 100 : 1)
        )
        commoditiesByKey[key] = synthesized
        commodityOrder.append(key)
        summary.warnings.append("Synthesised undeclared commodity \(space):\(id)")
        return synthesized
    }

    // MARK: Assembly

    func assemble() throws -> ImportResult {
        let root: Account
        if let rootGUID, let parsedRoot = accountsByGUID[rootGUID] {
            root = parsedRoot
        } else {
            root = Account(name: "Root Account", type: .root, commodity: .aud)
        }

        let book = Book(rootAccount: root)
        for key in commodityOrder {
            if let commodity = commoditiesByKey[key] { book.registerCommodity(commodity) }
        }

        // Build the account tree (parents are resolved from the full set).
        for guid in accountOrder {
            guard let account = accountsByGUID[guid], account.type != .root else { continue }
            if let parent = parentGUID[guid], let parentAccount = accountsByGUID[parent] {
                parentAccount.addChild(account)
            } else {
                root.addChild(account)
                if parentGUID[guid] != nil {
                    summary.warnings.append("Account '\(account.name)' had an unresolved parent; attached to root")
                }
            }
        }

        for txn in transactions { book.addTransaction(txn) }
        for price in prices { book.addPrice(price) }

        summary.commodityCount = commoditiesByKey.count
        summary.accountCount = book.accounts.count
        summary.transactionCount = transactions.count
        summary.splitCount = transactions.reduce(0) { $0 + $1.splits.count }
        summary.priceCount = prices.count
        summary.scrubIssues = Scrub.check(book)

        return ImportResult(book: book, summary: summary)
    }
}

// MARK: - Mutable builders

private struct CommodityBuilder {
    var space: String?
    var id: String?
    var name: String?
    var fraction: Int?

    func makeCommodity() -> Commodity {
        let namespace: CommodityNamespace = (space == "CURRENCY") ? .currency : .security(space ?? "")
        return Commodity(
            namespace: namespace,
            mnemonic: id ?? "",
            fullName: name ?? id ?? "",
            smallestFraction: fraction ?? (space == "CURRENCY" ? 100 : 1)
        )
    }
}

private struct AccountBuilder {
    var guid: GncGUID?
    var name = ""
    var type: String?
    var code = ""
    var descriptionText = ""
    var commoditySpace: String?
    var commodityID: String?
    var scu: Int?
    var parentGUID: GncGUID?
    var isPlaceholder = false
    var isHidden = false
}

private struct TransactionBuilder {
    var guid: GncGUID?
    var currencySpace: String?
    var currencyID: String?
    var datePosted: Date?
    var dateEntered: Date?
    var number = ""
    var descriptionText = ""
    var pendingSplits: [Split] = []
}

private struct SplitBuilder {
    var guid: GncGUID?
    var reconcileState: String?
    var value: Decimal?
    var quantity: Decimal?
    var accountGUID: GncGUID?
    var memo = ""
    var action = ""
}

private struct PriceBuilder {
    var guid: GncGUID?
    var commoditySpace: String?
    var commodityID: String?
    var currencySpace: String?
    var currencyID: String?
    var date: Date?
    var value: Decimal?
    var source = ""
    var type = ""
}
