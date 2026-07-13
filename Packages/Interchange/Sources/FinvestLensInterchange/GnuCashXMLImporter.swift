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
/// Slots (KVP) are captured **verbatim** into the engine's `KvpFrame`s on
/// book, commodity, account, transaction, and split (ADR-4), so unknown
/// GnuCash keys (colours, online ids, user symbols, reconcile info, …)
/// survive a round-trip untouched. `placeholder`/`hidden`/`notes` are lifted
/// into their engine properties, as are the commodity quote fields.
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
    private var bookGUID: GncGUID?
    private var transactions: [Transaction] = []
    private var prices: [Price] = []
    private var summary = ImportSummary()

    // Parse state.
    private var stack: [String] = []
    private var text = ""
    /// Inside `<gnc:template-transactions>` — the accounts and transactions
    /// there are scheduled-transaction internals (with their own ROOT), not
    /// ledger data. They are skipped so the template root can never hijack
    /// the book and template postings never pollute the register.
    private var inTemplateSection = false
    private var skippedTemplateAccounts = 0
    private var skippedTemplateTransactions = 0

    // Builders for the object currently being read.
    private var commodity: CommodityBuilder?
    private var account: AccountBuilder?
    private var transaction: TransactionBuilder?
    private var split: SplitBuilder?
    private var price: PriceBuilder?

    // KVP slot capture (ADR-4: slots are preserved verbatim so GnuCash
    // round-trips are lossless). Active while inside a recognised slots
    // container; nested frames/lists build a small tree that is converted
    // to a `KvpFrame` when the container closes.
    private var slotContainer: String?
    private var slotRoots: [SlotNode] = []
    private var slotStack: [SlotNode] = []
    private var bookKvp = KvpFrame()

    private final class SlotNode {
        var key = ""
        var valueType = "string"
        var scalar = ""
        var children: [SlotNode] = []
    }

    private var parentElement: String? { stack.count >= 2 ? stack[stack.count - 2] : nil }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        stack.append(name)
        text = ""

        switch name {
        case "gnc:template-transactions":
            inTemplateSection = true
        case "gnc:commodity": commodity = CommodityBuilder()
        case "gnc:account":
            if inTemplateSection { skippedTemplateAccounts += 1 } else { account = AccountBuilder() }
        case "gnc:transaction":
            if inTemplateSection { skippedTemplateTransactions += 1 } else { transaction = TransactionBuilder() }
        case "trn:split": split = SplitBuilder()
        case "price": price = PriceBuilder(); summary.priceCount += 1

        // Slot containers — capture only when the matching builder is live,
        // so budget/sx/template slots never leak onto the wrong object.
        case "act:slots" where account != nil,
             "trn:slots" where transaction != nil && split == nil,
             "split:slots" where split != nil,
             "cmdty:slots" where commodity != nil,
             "book:slots":
            slotContainer = name
        case "slot":
            guard slotContainer != nil else { break }
            let node = SlotNode()
            if let parent = slotStack.last { parent.children.append(node) } else { slotRoots.append(node) }
            slotStack.append(node)
        case "slot:value":
            guard slotContainer != nil else { break }
            slotStack.last?.valueType = attributes["type"] ?? "string"
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
        case "gnc:template-transactions":
            inTemplateSection = false

        // Book identity (preserved across round-trips).
        case "book:id": bookGUID = GncGUID(hex: value)

        // Commodity fields (context: definition vs. reference).
        case "cmdty:space": setCommodityField(space: value)
        case "cmdty:id": setCommodityField(id: value)
        case "cmdty:name": commodity?.name = value
        case "cmdty:fraction": commodity?.fraction = Int(value)
        case "cmdty:xcode": commodity?.xcode = value
        case "cmdty:get_quotes": commodity?.getQuotes = true   // presence flag
        case "cmdty:quote_source": commodity?.quoteSource = value
        case "cmdty:quote_tz": commodity?.quoteTimezone = value // "" when empty
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
        case "ts:date":
            if slotContainer != nil, parentElement == "slot:value" {
                slotStack.last?.scalar = value          // timespec slot
            } else {
                setTransactionDate(value)
            }
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

        // KVP slots (preserved verbatim, ADR-4).
        case "slot:key":
            slotStack.last?.key = value
        case "gdate":
            if slotContainer != nil { slotStack.last?.scalar = value }
        case "slot:value":
            // Scalar text; frames/lists keep "" and use children instead.
            // gdate/timespec scalars were already set by their child element.
            if slotContainer != nil, !value.isEmpty { slotStack.last?.scalar = value }
        case "slot":
            if slotContainer != nil, !slotStack.isEmpty { slotStack.removeLast() }
        case "act:slots", "trn:slots", "split:slots", "cmdty:slots", "book:slots":
            finishSlotContainer(name)

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

    /// Converts the captured slot tree to a frame and delivers it, lifting
    /// the keys FinvestLens models as properties (`placeholder`, `hidden`,
    /// `notes`) out of the frame so there is a single source of truth.
    private func finishSlotContainer(_ container: String) {
        guard slotContainer == container else { return }
        var frame = KvpFrame()
        for node in slotRoots where !node.key.isEmpty {
            if let value = Self.kvpValue(of: node) { frame[node.key] = value }
        }
        slotRoots = []
        slotStack = []
        slotContainer = nil

        switch container {
        case "act:slots":
            if case let .string(text)? = frame["placeholder"] {
                account?.isPlaceholder = (text == "true"); frame["placeholder"] = nil
            }
            if case let .string(text)? = frame["hidden"] {
                account?.isHidden = (text == "true"); frame["hidden"] = nil
            }
            if case let .string(text)? = frame["notes"] {
                account?.notes = text; frame["notes"] = nil
            }
            account?.kvp = frame
        case "trn:slots":
            if case let .string(text)? = frame["notes"] {
                transaction?.notes = text; frame["notes"] = nil
            }
            transaction?.kvp = frame
        case "split:slots":
            split?.kvp = frame
        case "cmdty:slots":
            commodity?.kvp = frame
        case "book:slots":
            bookKvp = frame
        default:
            break
        }
    }

    private static func kvpValue(of node: SlotNode) -> KvpValue? {
        switch node.valueType {
        case "integer": return Int64(node.scalar).map(KvpValue.int64)
        case "double": return Double(node.scalar).map(KvpValue.double)
        case "numeric": return GnuCashNumeric.parse(node.scalar).map(KvpValue.numeric)
        case "guid": return GncGUID(hex: node.scalar).map(KvpValue.guid)
        case "gdate", "timespec": return GnuCashDate.parse(node.scalar).map(KvpValue.date)
        case "frame":
            var frame = KvpFrame()
            for child in node.children where !child.key.isEmpty {
                if let value = kvpValue(of: child) { frame[child.key] = value }
            }
            return .frame(frame)
        case "list":
            return .list(node.children.compactMap { kvpValue(of: $0) })
        default:
            return .string(node.scalar)
        }
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
        guard let builder = account else { return }   // template section — already counted
        guard let guid = builder.guid else {
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
        acct.notes = builder.notes
        acct.kvp = builder.kvp
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
        engineSplit.kvp = builder.kvp
        transaction?.pendingSplits.append(engineSplit)
    }

    private func finishTransaction() {
        defer { transaction = nil }
        guard let builder = transaction else { return }   // template section — already counted
        guard let guid = builder.guid else {
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
        txn.notes = builder.notes
        txn.kvp = builder.kvp
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

        if skippedTemplateAccounts + skippedTemplateTransactions > 0 {
            summary.warnings.append(
                "Skipped \(skippedTemplateAccounts) template account(s) and " +
                "\(skippedTemplateTransactions) template transaction(s) " +
                "(scheduled-transaction internals)")
        }

        let book = Book(guid: bookGUID ?? .random(), rootAccount: root, kvp: bookKvp)
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
    var xcode: String?
    var getQuotes = false
    var quoteSource: String?
    var quoteTimezone: String?
    var kvp = KvpFrame()

    func makeCommodity() -> Commodity {
        let namespace: CommodityNamespace = (space == "CURRENCY") ? .currency : .security(space ?? "")
        return Commodity(
            namespace: namespace,
            mnemonic: id ?? "",
            fullName: name ?? id ?? "",
            smallestFraction: fraction ?? (space == "CURRENCY" ? 100 : 1),
            exchangeCode: xcode,
            getQuotes: getQuotes,
            quoteSource: quoteSource,
            quoteTimezone: quoteTimezone,
            kvp: kvp
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
    var notes = ""
    var kvp = KvpFrame()
}

private struct TransactionBuilder {
    var guid: GncGUID?
    var currencySpace: String?
    var currencyID: String?
    var datePosted: Date?
    var dateEntered: Date?
    var number = ""
    var descriptionText = ""
    var notes = ""
    var kvp = KvpFrame()
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
    var kvp = KvpFrame()
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
