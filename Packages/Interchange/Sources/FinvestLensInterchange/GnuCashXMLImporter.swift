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
/// (`FR-IMP-08`). Prices are mapped (`FR-IMP-02`) and **business objects**
/// (customers/vendors/employees/jobs/invoices/entries/lots/terms/tax-tables)
/// are imported (`FR-IMP-05`, see `assembleBusiness`). GnuCash-native
/// **budgets** (`<gnc:budget>`, `FR-IMP-04`) and **scheduled transactions**
/// (`<gnc:schedxaction>`, `FR-IMP-03`) are not yet mapped — they are silently
/// skipped (FinvestLens keeps its own budgets/SX in KVP slots).
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

    // Business builders and their finished collections.
    private var billTerm: BillTermBuilder?
    private var taxTable: TaxTableBuilder?
    private var taxEntry: TaxEntryBuilder?
    private var party: PartyBuilder?          // active customer/vendor/employee
    private var partyKind: OwnerType?
    private var job: JobBuilder?
    private var invoice: InvoiceBuilder?
    private var entry: EntryBuilder?
    private var lot: LotBuilder?
    private var billTermBuilders: [BillTermBuilder] = []
    private var taxTableBuilders: [TaxTableBuilder] = []
    private var customerBuilders: [PartyBuilder] = []
    private var vendorBuilders: [PartyBuilder] = []
    private var employeeBuilders: [PartyBuilder] = []
    private var jobBuilders: [JobBuilder] = []
    private var invoiceBuilders: [InvoiceBuilder] = []
    private var entryBuilders: [EntryBuilder] = []
    private var lotBuilders: [LotBuilder] = []
    private var splitLotGUID: [GncGUID: GncGUID] = [:]   // split guid → its lot

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
        /// True for a list element, which GnuCash writes as a bare `<slot:value>`
        /// (no `<slot>` wrapper) — so the value element itself is its own node.
        var openedByValue = false
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

        // Business objects.
        case "gnc:GncBillTerm": billTerm = BillTermBuilder()
        case "gnc:GncTaxTable": taxTable = TaxTableBuilder()
        case "gnc:GncTaxTableEntry": taxEntry = TaxEntryBuilder()
        case "gnc:GncCustomer": party = PartyBuilder(); partyKind = .customer
        case "gnc:GncVendor": party = PartyBuilder(); partyKind = .vendor
        case "gnc:GncEmployee": party = PartyBuilder(); partyKind = .employee
        case "gnc:GncJob": job = JobBuilder()
        case "gnc:GncInvoice": invoice = InvoiceBuilder()
        case "gnc:GncEntry": entry = EntryBuilder()
        case "gnc:lot" where account != nil:
            lot = LotBuilder(); lot?.accountGUID = account?.guid

        // Slot containers — capture only when the matching builder is live,
        // so budget/sx/template slots never leak onto the wrong object.
        case "act:slots" where account != nil,
             "trn:slots" where transaction != nil && split == nil,
             "split:slots" where split != nil,
             "cmdty:slots" where commodity != nil,
             "lot:slots" where lot != nil,
             "book:slots":
            slotContainer = name
        case "slot":
            guard slotContainer != nil else { break }
            let node = SlotNode()
            if let parent = slotStack.last { parent.children.append(node) } else { slotRoots.append(node) }
            slotStack.append(node)
        case "slot:value":
            guard slotContainer != nil else { break }
            let type = attributes["type"] ?? "string"
            if let parent = slotStack.last, parent.valueType == "list" {
                // A bare list element: it has no <slot> wrapper, so the value
                // element becomes its own child node.
                let node = SlotNode()
                node.valueType = type
                node.openedByValue = true
                parent.children.append(node)
                slotStack.append(node)
            } else {
                slotStack.last?.valueType = type
            }
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
            guard slotContainer != nil else { break }
            if let node = slotStack.last, node.openedByValue {
                // A bare list element closes here — capture its scalar and pop.
                if !value.isEmpty { node.scalar = value }
                slotStack.removeLast()
            } else if !value.isEmpty {
                slotStack.last?.scalar = value
            }
        case "slot":
            if slotContainer != nil, !slotStack.isEmpty { slotStack.removeLast() }
        case "act:slots", "trn:slots", "split:slots", "cmdty:slots", "book:slots", "lot:slots":
            finishSlotContainer(name)

        // MARK: Business fields

        // Billing terms.
        case "billterm:guid": billTerm?.guid = GncGUID(hex: value)
        case "billterm:name": billTerm?.name = value
        case "billterm:desc": billTerm?.desc = value
        case "billterm:invisible": billTerm?.invisible = (value == "1")
        case "bt-days:due-days": billTerm?.kind = "days"; billTerm?.dueDays = Int(value) ?? 0
        case "bt-days:disc-days": billTerm?.discDays = Int(value) ?? 0
        case "bt-days:discount": billTerm?.discount = GnuCashNumeric.parse(value) ?? 0
        case "bt-prox:due-day": billTerm?.kind = "prox"; billTerm?.dueDays = Int(value) ?? 0
        case "bt-prox:disc-day": billTerm?.discDays = Int(value) ?? 0
        case "bt-prox:cutoff-day": billTerm?.cutoff = Int(value) ?? 0
        case "bt-prox:discount": billTerm?.discount = GnuCashNumeric.parse(value) ?? 0
        case "gnc:GncBillTerm": if let b = billTerm { billTermBuilders.append(b) }; billTerm = nil

        // Tax tables.
        case "taxtable:guid": taxTable?.guid = GncGUID(hex: value)
        case "taxtable:name": taxTable?.name = value
        case "taxtable:invisible": taxTable?.invisible = (value == "1")
        case "tte:acct": taxEntry?.accountGUID = GncGUID(hex: value)
        case "tte:type": taxEntry?.type = value
        case "tte:amount": taxEntry?.amount = GnuCashNumeric.parse(value) ?? 0
        case "gnc:GncTaxTableEntry": if let e = taxEntry { taxTable?.entries.append(e) }; taxEntry = nil
        case "gnc:GncTaxTable": if let t = taxTable { taxTableBuilders.append(t) }; taxTable = nil

        // Parties (customer / vendor / employee share the `party` builder).
        case "cust:guid", "vendor:guid", "employee:guid": party?.guid = GncGUID(hex: value)
        case "cust:name", "vendor:name": party?.name = value
        case "employee:username": party?.name = value
        case "cust:id", "vendor:id", "employee:id": party?.id = value
        case "cust:notes", "vendor:notes": party?.notes = value
        case "cust:active", "vendor:active", "employee:active": party?.active = (value == "1")
        case "cust:discount": party?.discount = GnuCashNumeric.parse(value) ?? 0
        case "cust:credit": party?.credit = GnuCashNumeric.parse(value) ?? 0
        case "employee:rate": party?.rate = GnuCashNumeric.parse(value) ?? 0
        case "cust:use-tt", "vendor:use-tt": party?.useTaxTable = (value == "1")
        case "cust:terms", "vendor:terms": party?.termsGUID = GncGUID(hex: value)
        case "cust:taxtable", "vendor:taxtable": party?.taxTableGUID = GncGUID(hex: value)
        case "employee:ccard": party?.creditAccountGUID = GncGUID(hex: value)
        case "addr:name": setAddress { $0.name = value }
        case "addr:addr1": setAddress { $0.line1 = value }
        case "addr:addr2": setAddress { $0.line2 = value }
        case "addr:addr3": setAddress { $0.line3 = value }
        case "addr:addr4": setAddress { $0.line4 = value }
        case "addr:phone": setAddress { $0.phone = value }
        case "addr:fax": setAddress { $0.fax = value }
        case "addr:email": setAddress { $0.email = value }
        case "gnc:GncCustomer": if let p = party { customerBuilders.append(p) }; party = nil; partyKind = nil
        case "gnc:GncVendor": if let p = party { vendorBuilders.append(p) }; party = nil; partyKind = nil
        case "gnc:GncEmployee": if let p = party { employeeBuilders.append(p) }; party = nil; partyKind = nil

        // Owner references (inside invoice:owner / job:owner).
        case "owner:type":
            if invoice != nil { invoice?.owner.type = value } else if job != nil { job?.owner.type = value }
        case "owner:id":
            if invoice != nil { invoice?.owner.guid = GncGUID(hex: value) }
            else if job != nil { job?.owner.guid = GncGUID(hex: value) }

        // Jobs.
        case "job:guid": job?.guid = GncGUID(hex: value)
        case "job:id": job?.id = value
        case "job:name": job?.name = value
        case "job:reference": job?.reference = value
        case "job:active": job?.active = (value == "1")
        case "gnc:GncJob": if let j = job { jobBuilders.append(j) }; job = nil

        // Invoices.
        case "invoice:guid": invoice?.guid = GncGUID(hex: value)
        case "invoice:id": invoice?.id = value
        case "invoice:terms": invoice?.termsGUID = GncGUID(hex: value)
        case "invoice:billing_id": invoice?.billingID = value
        case "invoice:notes": invoice?.notes = value
        case "invoice:active": invoice?.active = (value == "1")
        case "invoice:postacc": invoice?.postAccountGUID = GncGUID(hex: value)
        case "invoice:posttxn": invoice?.postTxnGUID = GncGUID(hex: value)
        case "invoice:postlot": invoice?.postLotGUID = GncGUID(hex: value)
        case "gnc:GncInvoice": if let i = invoice { invoiceBuilders.append(i) }; invoice = nil

        // Entries (i- for invoices, b- for bills).
        case "entry:guid": entry?.guid = GncGUID(hex: value)
        case "entry:description": entry?.desc = value
        case "entry:action": entry?.action = value
        case "entry:qty": entry?.qty = GnuCashNumeric.parse(value) ?? 1
        case "entry:i-acct", "entry:b-acct": entry?.accountGUID = GncGUID(hex: value)
        case "entry:i-price", "entry:b-price": entry?.price = GnuCashNumeric.parse(value) ?? 0
        case "entry:i-discount": entry?.discount = GnuCashNumeric.parse(value) ?? 0
        case "entry:i-disc-type": entry?.discType = value
        case "entry:i-disc-how": entry?.discHow = value
        case "entry:i-taxable", "entry:b-taxable": entry?.taxable = (value == "1")
        case "entry:i-taxincluded", "entry:b-taxincluded": entry?.taxIncluded = (value == "1")
        case "entry:i-taxtable", "entry:b-taxtable": entry?.taxTableGUID = GncGUID(hex: value)
        case "entry:invoice", "entry:bill": entry?.invoiceGUID = GncGUID(hex: value)
        case "gnc:GncEntry": if let e = entry { entryBuilders.append(e) }; entry = nil

        // Lots (inside an account) and split membership.
        case "lot:id": lot?.guid = GncGUID(hex: value)
        case "gnc:lot": if let l = lot { lotBuilders.append(l) }; lot = nil
        case "split:lot": split?.lotGUID = GncGUID(hex: value)

        default: break
        }
    }

    /// Applies `mutate` to the active party's address.
    private func setAddress(_ mutate: (inout BusinessAddress) -> Void) {
        guard party != nil else { return }
        mutate(&party!.address)
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
        // Business currencies.
        case "cust:currency", "vendor:currency", "employee:currency":
            if let space { party?.currencySpace = space }
            if let id { party?.currencyID = id }
        case "invoice:currency":
            if let space { invoice?.currencySpace = space }
            if let id { invoice?.currencyID = id }
        default:
            break
        }
    }

    private func setTransactionDate(_ raw: String) {
        guard let date = GnuCashDate.parse(raw) else { return }
        switch parentElement {
        case "trn:date-posted": transaction?.datePosted = date
        case "trn:date-entered": transaction?.dateEntered = date
        case "split:reconcile-date": split?.reconcileDate = date
        case "price:time": price?.date = date
        case "invoice:opened": invoice?.opened = date
        case "invoice:posted": invoice?.posted = date
        case "entry:date": entry?.date = date
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
        case "lot:slots":
            if case let .string(text)? = frame["title"] { lot?.title = text; frame["title"] = nil }
            if case let .string(text)? = frame["notes"] { lot?.notes = text; frame["notes"] = nil }
            if case let .int64(n)? = frame["closed"] { lot?.closed = (n != 0); frame["closed"] = nil }
            lot?.kvp = frame   // keep gncInvoice/gncOwner for a faithful re-export
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
            reconcileDate: builder.reconcileDate,
            memo: builder.memo,
            action: builder.action
        )
        engineSplit.kvp = builder.kvp
        if let lotGUID = builder.lotGUID { splitLotGUID[engineSplit.guid] = lotGUID }
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

        assembleBusiness(into: book)

        summary.commodityCount = commoditiesByKey.count
        summary.accountCount = book.accounts.count
        summary.transactionCount = transactions.count
        summary.splitCount = transactions.reduce(0) { $0 + $1.splits.count }
        summary.priceCount = prices.count
        summary.scrubIssues = Scrub.check(book)

        return ImportResult(book: book, summary: summary)
    }

    // MARK: - Business assembly

    private func assembleBusiness(into book: Book) {
        func account(_ guid: GncGUID?) -> Account? { guid.flatMap { accountsByGUID[$0] } }
        func currency(_ space: String?, _ id: String?) -> Commodity {
            resolveCommodity(space: space, id: id, fractionHint: nil)
        }

        var terms: [GncGUID: BillTerm] = [:]
        for b in billTermBuilders {
            guard let guid = b.guid else { continue }
            let term = BillTerm(guid: guid, name: b.name, termDescription: b.desc,
                                kind: b.kind == "prox" ? .proximo : .days, dueDays: b.dueDays,
                                discountDays: b.discDays, cutoff: b.cutoff, discountPercent: b.discount,
                                active: !b.invisible)
            terms[guid] = term; book.addBillTerm(term)
        }
        var tables: [GncGUID: TaxTable] = [:]
        for b in taxTableBuilders {
            guard let guid = b.guid else { continue }
            let entries = b.entries.compactMap { e -> TaxTableEntry? in
                guard let acc = account(e.accountGUID) else { return nil }
                return TaxTableEntry(account: acc, kind: e.type == "VALUE" ? .value : .percentage,
                                     amount: e.amount)
            }
            let table = TaxTable(guid: guid, name: b.name, entries: entries, active: !b.invisible)
            tables[guid] = table; book.addTaxTable(table)
        }
        var customers: [GncGUID: Customer] = [:]
        for b in customerBuilders {
            guard let guid = b.guid else { continue }
            let c = Customer(guid: guid, id: b.id, name: b.name, address: b.address, notes: b.notes,
                             active: b.active, currency: currency(b.currencySpace, b.currencyID),
                             terms: b.termsGUID.flatMap { terms[$0] },
                             taxTable: b.taxTableGUID.flatMap { tables[$0] },
                             taxTableOverride: b.useTaxTable, discountPercent: b.discount,
                             creditLimit: b.credit)
            customers[guid] = c; book.addCustomer(c)
        }
        var vendors: [GncGUID: Vendor] = [:]
        for b in vendorBuilders {
            guard let guid = b.guid else { continue }
            let v = Vendor(guid: guid, id: b.id, name: b.name, address: b.address, notes: b.notes,
                           active: b.active, currency: currency(b.currencySpace, b.currencyID),
                           terms: b.termsGUID.flatMap { terms[$0] },
                           taxTable: b.taxTableGUID.flatMap { tables[$0] }, taxTableOverride: b.useTaxTable)
            vendors[guid] = v; book.addVendor(v)
        }
        var employees: [GncGUID: Employee] = [:]
        for b in employeeBuilders {
            guard let guid = b.guid else { continue }
            let e = Employee(guid: guid, id: b.id, username: b.name, address: b.address, notes: b.notes,
                             active: b.active, currency: currency(b.currencySpace, b.currencyID),
                             hourlyRate: b.rate, creditAccount: account(b.creditAccountGUID))
            employees[guid] = e; book.addEmployee(e)
        }
        func owner(_ ref: OwnerRef, allowJob: Bool = true, jobs: [GncGUID: Job] = [:]) -> BusinessOwner? {
            guard let guid = ref.guid else { return nil }
            switch ref.type {
            case "gncCustomer": return customers[guid].map { .customer($0) }
            case "gncVendor": return vendors[guid].map { .vendor($0) }
            case "gncEmployee": return employees[guid].map { .employee($0) }
            case "gncJob": return allowJob ? jobs[guid].map { .job($0) } : nil
            default: return nil
            }
        }
        var jobs: [GncGUID: Job] = [:]
        for b in jobBuilders {
            guard let guid = b.guid, let ownr = owner(b.owner, allowJob: false) else { continue }
            let job = Job(guid: guid, id: b.id, name: b.name, reference: b.reference,
                          active: b.active, owner: ownr)
            jobs[guid] = job; book.addJob(job)
        }
        var splitsByGUID: [GncGUID: Split] = [:]
        for txn in book.transactions { for s in txn.splits { splitsByGUID[s.guid] = s } }
        var lots: [GncGUID: Lot] = [:]
        for b in lotBuilders {
            guard let guid = b.guid else { continue }
            let lot = Lot(guid: guid, account: account(b.accountGUID), title: b.title,
                          notes: b.notes, isClosed: b.closed, kvp: b.kvp)
            lots[guid] = lot; book.addLot(lot)
        }
        for (splitGUID, lotGUID) in splitLotGUID {
            if let split = splitsByGUID[splitGUID], let lot = lots[lotGUID] { lot.add(split) }
        }
        var entriesByInvoice: [GncGUID: [InvoiceEntry]] = [:]
        for b in entryBuilders {
            guard let invGUID = b.invoiceGUID else { continue }
            entriesByInvoice[invGUID, default: []].append(InvoiceEntry(
                guid: b.guid ?? .random(), date: b.date ?? Date(), entryDescription: b.desc,
                action: b.action, account: account(b.accountGUID), quantity: b.qty, price: b.price,
                discount: b.discount, discountType: b.discType == "VALUE" ? .value : .percentage,
                discountHow: DiscountHow(gnuCashName: b.discHow),
                taxable: b.taxable, taxIncluded: b.taxIncluded,
                taxTable: b.taxTableGUID.flatMap { tables[$0] }))
        }
        for b in invoiceBuilders {
            guard let guid = b.guid, let ownr = owner(b.owner, jobs: jobs) else { continue }
            let kind: InvoiceKind
            switch ownr {
            case .customer: kind = .invoice
            case .vendor: kind = .bill
            case .employee: kind = .voucher
            case .job(let j): kind = j.owner.type == .customer ? .invoice : .bill
            }
            let invoice = Invoice(guid: guid, id: b.id, kind: kind, owner: ownr,
                                  dateOpened: b.opened ?? Date(), datePosted: b.posted,
                                  terms: b.termsGUID.flatMap { terms[$0] }, billingID: b.billingID,
                                  notes: b.notes, currency: currency(b.currencySpace, b.currencyID),
                                  entries: entriesByInvoice[guid] ?? [], active: b.active)
            invoice.postedAccount = account(b.postAccountGUID)
            invoice.postedTransaction = b.postTxnGUID.flatMap { g in book.transactions.first { $0.guid == g } }
            invoice.postedLot = b.postLotGUID.flatMap { lots[$0] }
            if invoice.datePosted != nil, let posted = invoice.datePosted {
                invoice.dueDate = invoice.terms?.dueDate(postedOn: posted)
            }
            book.addInvoice(invoice)
        }
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
    var reconcileDate: Date?
    var value: Decimal?
    var quantity: Decimal?
    var accountGUID: GncGUID?
    var memo = ""
    var action = ""
    var kvp = KvpFrame()
    var lotGUID: GncGUID?
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

// MARK: Business builders

struct OwnerRef { var type: String?; var guid: GncGUID? }

struct BillTermBuilder {
    var guid: GncGUID?; var name = ""; var desc = ""; var kind = "days"
    var dueDays = 0; var discDays = 0; var cutoff = 0; var discount: Decimal = 0; var invisible = false
}
struct TaxEntryBuilder { var accountGUID: GncGUID?; var type = "PERCENT"; var amount: Decimal = 0 }
struct TaxTableBuilder {
    var guid: GncGUID?; var name = ""; var invisible = false; var entries: [TaxEntryBuilder] = []
}
struct PartyBuilder {   // customer / vendor / employee share these
    var guid: GncGUID?; var name = ""; var id = ""; var notes = ""; var active = true
    var address = BusinessAddress(); var currencySpace: String?; var currencyID: String?
    var termsGUID: GncGUID?; var taxTableGUID: GncGUID?; var useTaxTable = false
    var discount: Decimal = 0; var credit: Decimal = 0; var rate: Decimal = 0
    var creditAccountGUID: GncGUID?
}
struct JobBuilder {
    var guid: GncGUID?; var id = ""; var name = ""; var reference = ""; var active = true
    var owner = OwnerRef()
}
struct InvoiceBuilder {
    var guid: GncGUID?; var id = ""; var owner = OwnerRef(); var opened: Date?; var posted: Date?
    var termsGUID: GncGUID?; var billingID = ""; var notes = ""; var active = true
    var currencySpace: String?; var currencyID: String?
    var postAccountGUID: GncGUID?; var postTxnGUID: GncGUID?; var postLotGUID: GncGUID?
}
struct EntryBuilder {
    var guid: GncGUID?; var date: Date?; var desc = ""; var action = ""; var qty: Decimal = 1
    var accountGUID: GncGUID?; var price: Decimal = 0; var discount: Decimal = 0
    var discType = "PERCENT"; var discHow = "PRETAX"; var taxable = false; var taxIncluded = false
    var taxTableGUID: GncGUID?; var invoiceGUID: GncGUID?
}
struct LotBuilder {
    var guid: GncGUID?; var accountGUID: GncGUID?; var title = ""; var notes = ""; var closed = false
    var kvp = KvpFrame()
}
