//
//  GnuCashXMLExporter.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Writes an engine ``Book`` to the GnuCash XML v2 format (`FR-EXP-01`).
///
/// The output mirrors what ``GnuCashXMLImporter`` reads — commodities, the
/// account hierarchy, and transactions/splits — preserving GUIDs and the
/// account placeholder/hidden flags (`FR-EXP-03`). Amounts are emitted as
/// exact GnuCash rationals (`num/denom`), so no precision is lost. Prices and
/// **business objects** (customers/vendors/employees/jobs/invoices/entries,
/// with `<act:lots>`/`<split:lot>`) are written too. GnuCash-native budgets
/// and scheduled transactions are not written (FinvestLens keeps its own in
/// KVP slots).
public enum GnuCashXMLExporter {

    /// Serialises `book` to GnuCash XML, optionally gzip-compressed
    /// (as GnuCash writes by default).
    public static func export(_ book: Book, compressed: Bool = false) -> Data {
        let xml = makeXML(book)
        let data = Data(xml.utf8)
        return compressed ? Gzip.compress(data) : data
    }

    // MARK: XML construction

    private static func makeXML(_ book: Book) -> String {
        var out = """
        <?xml version="1.0" encoding="utf-8"?>
        <gnc-v2
             xmlns:gnc="http://www.gnucash.org/XML/gnc"
             xmlns:act="http://www.gnucash.org/XML/act"
             xmlns:book="http://www.gnucash.org/XML/book"
             xmlns:cd="http://www.gnucash.org/XML/cd"
             xmlns:cmdty="http://www.gnucash.org/XML/cmdty"
             xmlns:trn="http://www.gnucash.org/XML/trn"
             xmlns:split="http://www.gnucash.org/XML/split"
             xmlns:slot="http://www.gnucash.org/XML/slot"
             xmlns:price="http://www.gnucash.org/XML/price"
             xmlns:ts="http://www.gnucash.org/XML/ts"
             xmlns:lot="http://www.gnucash.org/XML/lot"
             xmlns:addr="http://www.gnucash.org/XML/addr"
             xmlns:billterm="http://www.gnucash.org/XML/billterm"
             xmlns:bt-days="http://www.gnucash.org/XML/bt-days"
             xmlns:bt-prox="http://www.gnucash.org/XML/bt-prox"
             xmlns:cust="http://www.gnucash.org/XML/cust"
             xmlns:vendor="http://www.gnucash.org/XML/vendor"
             xmlns:employee="http://www.gnucash.org/XML/employee"
             xmlns:entry="http://www.gnucash.org/XML/entry"
             xmlns:invoice="http://www.gnucash.org/XML/invoice"
             xmlns:job="http://www.gnucash.org/XML/job"
             xmlns:owner="http://www.gnucash.org/XML/owner"
             xmlns:taxtable="http://www.gnucash.org/XML/taxtable"
             xmlns:tte="http://www.gnucash.org/XML/tte">
        <gnc:count-data cd:type="book">1</gnc:count-data>
        <gnc:book version="2.0.0">
        <book:id type="guid">\(book.guid.hexString)</book:id>

        """

        out += slotsBlock(book.kvp.slots.sorted { $0.key < $1.key },
                          container: "book:slots", indent: "")

        let accounts = [book.rootAccount] + book.rootAccount.descendants
        // Lots keyed by their account, and each split's owning lot, so lots nest
        // under their account and splits carry a `<split:lot>` back-reference.
        var lotsByAccount: [ObjectIdentifier: [Lot]] = [:]
        var lotBySplit: [GncGUID: GncGUID] = [:]
        for lot in book.lots {
            if let account = lot.account { lotsByAccount[ObjectIdentifier(account), default: []].append(lot) }
            for split in lot.splits { lotBySplit[split.guid] = lot.guid }
        }

        out += "<gnc:count-data cd:type=\"commodity\">\(book.commodities.count)</gnc:count-data>\n"
        out += "<gnc:count-data cd:type=\"account\">\(accounts.count)</gnc:count-data>\n"
        out += "<gnc:count-data cd:type=\"transaction\">\(book.transactions.count)</gnc:count-data>\n"
        out += businessCountData(book)

        for commodity in book.commodities {
            out += commodityBlock(commodity)
        }
        if !book.prices.isEmpty {
            out += priceDBBlock(book.prices)
        }
        for account in accounts {
            out += accountBlock(account, lots: lotsByAccount[ObjectIdentifier(account)] ?? [])
        }
        for transaction in book.transactions {
            out += transactionBlock(transaction, lotBySplit: lotBySplit)
        }

        out += businessBlocks(book)

        out += "</gnc:book>\n</gnc-v2>\n"
        return out
    }

    private static func priceDBBlock(_ prices: [Price]) -> String {
        var block = "<gnc:pricedb version=\"1\">\n"
        for price in prices {
            block += "  <price>\n"
            block += "    <price:id type=\"guid\">\(price.guid.hexString)</price:id>\n"
            block += "    <price:commodity>\n"
            block += "      <cmdty:space>\(escape(namespace(price.commodity.namespace)))</cmdty:space>\n"
            block += "      <cmdty:id>\(escape(price.commodity.mnemonic))</cmdty:id>\n"
            block += "    </price:commodity>\n"
            block += "    <price:currency>\n"
            block += "      <cmdty:space>\(escape(namespace(price.currency.namespace)))</cmdty:space>\n"
            block += "      <cmdty:id>\(escape(price.currency.mnemonic))</cmdty:id>\n"
            block += "    </price:currency>\n"
            block += "    <price:time><ts:date>\(GnuCashDate.format(price.date))</ts:date></price:time>\n"
            if !price.source.isEmpty { block += "    <price:source>\(escape(price.source))</price:source>\n" }
            if !price.type.isEmpty { block += "    <price:type>\(escape(price.type))</price:type>\n" }
            block += "    <price:value>\(rational(price.value, fallbackFraction: price.currency.smallestFraction))</price:value>\n"
            block += "  </price>\n"
        }
        block += "</gnc:pricedb>\n"
        return block
    }

    private static func commodityBlock(_ commodity: Commodity) -> String {
        var block = "<gnc:commodity version=\"2.0.0\">\n"
        block += "  <cmdty:space>\(escape(namespace(commodity.namespace)))</cmdty:space>\n"
        block += "  <cmdty:id>\(escape(commodity.mnemonic))</cmdty:id>\n"
        if !commodity.fullName.isEmpty {
            block += "  <cmdty:name>\(escape(commodity.fullName))</cmdty:name>\n"
        }
        if let xcode = commodity.exchangeCode {
            block += "  <cmdty:xcode>\(escape(xcode))</cmdty:xcode>\n"
        }
        block += "  <cmdty:fraction>\(commodity.smallestFraction)</cmdty:fraction>\n"
        if commodity.getQuotes {
            block += "  <cmdty:get_quotes/>\n"
        }
        if let source = commodity.quoteSource {
            block += "  <cmdty:quote_source>\(escape(source))</cmdty:quote_source>\n"
        }
        if let timezone = commodity.quoteTimezone {
            block += timezone.isEmpty
                ? "  <cmdty:quote_tz/>\n"
                : "  <cmdty:quote_tz>\(escape(timezone))</cmdty:quote_tz>\n"
        }
        block += slotsBlock(commodity.kvp.slots.sorted { $0.key < $1.key },
                            container: "cmdty:slots", indent: "  ")
        block += "</gnc:commodity>\n"
        return block
    }

    private static func accountBlock(_ account: Account, lots: [Lot] = []) -> String {
        var block = "<gnc:account version=\"2.0.0\">\n"
        block += "  <act:name>\(escape(account.name))</act:name>\n"
        block += "  <act:id type=\"guid\">\(account.guid.hexString)</act:id>\n"
        block += "  <act:type>\(account.type.rawValue)</act:type>\n"
        block += "  <act:commodity>\n"
        block += "    <cmdty:space>\(escape(namespace(account.commodity.namespace)))</cmdty:space>\n"
        block += "    <cmdty:id>\(escape(account.commodity.mnemonic))</cmdty:id>\n"
        block += "  </act:commodity>\n"
        block += "  <act:commodity-scu>\(account.commodity.smallestFraction)</act:commodity-scu>\n"
        if !account.code.isEmpty {
            block += "  <act:code>\(escape(account.code))</act:code>\n"
        }
        if !account.accountDescription.isEmpty {
            block += "  <act:description>\(escape(account.accountDescription))</act:description>\n"
        }
        var slotEntries: [(String, KvpValue)] = []
        if account.isPlaceholder { slotEntries.append(("placeholder", .string("true"))) }
        if account.isHidden { slotEntries.append(("hidden", .string("true"))) }
        if !account.notes.isEmpty { slotEntries.append(("notes", .string(account.notes))) }
        slotEntries += account.kvp.slots.sorted { $0.key < $1.key }
        block += slotsBlock(slotEntries, container: "act:slots", indent: "  ")
        if let parent = account.parent {
            block += "  <act:parent type=\"guid\">\(parent.guid.hexString)</act:parent>\n"
        }
        block += lotsBlock(lots)
        block += "</gnc:account>\n"
        return block
    }

    /// The account's business lots (A/R / A/P), each with its title and closed
    /// flag carried as GnuCash slots.
    private static func lotsBlock(_ lots: [Lot]) -> String {
        guard !lots.isEmpty else { return "" }
        var block = "  <act:lots>\n"
        for lot in lots {
            block += "    <gnc:lot version=\"2.0.0\">\n"
            block += "      <lot:id type=\"guid\">\(lot.guid.hexString)</lot:id>\n"
            var slots: [(String, KvpValue)] = []
            if !lot.title.isEmpty { slots.append(("title", .string(lot.title))) }
            if !lot.notes.isEmpty { slots.append(("notes", .string(lot.notes))) }
            if lot.isClosed { slots.append(("closed", .int64(1))) }
            slots += lot.kvp.slots.sorted { $0.key < $1.key }
            block += slotsBlock(slots, container: "lot:slots", indent: "      ")
            block += "    </gnc:lot>\n"
        }
        block += "  </act:lots>\n"
        return block
    }

    private static func transactionBlock(_ transaction: Transaction,
                                         lotBySplit: [GncGUID: GncGUID] = [:]) -> String {
        var block = "<gnc:transaction version=\"2.0.0\">\n"
        block += "  <trn:id type=\"guid\">\(transaction.guid.hexString)</trn:id>\n"
        block += "  <trn:currency>\n"
        block += "    <cmdty:space>\(escape(namespace(transaction.currency.namespace)))</cmdty:space>\n"
        block += "    <cmdty:id>\(escape(transaction.currency.mnemonic))</cmdty:id>\n"
        block += "  </trn:currency>\n"
        if !transaction.number.isEmpty {
            block += "  <trn:num>\(escape(transaction.number))</trn:num>\n"
        }
        block += "  <trn:date-posted><ts:date>\(GnuCashDate.format(transaction.datePosted))</ts:date></trn:date-posted>\n"
        block += "  <trn:date-entered><ts:date>\(GnuCashDate.format(transaction.dateEntered))</ts:date></trn:date-entered>\n"
        block += "  <trn:description>\(escape(transaction.transactionDescription))</trn:description>\n"
        var slotEntries: [(String, KvpValue)] = []
        if !transaction.notes.isEmpty { slotEntries.append(("notes", .string(transaction.notes))) }
        slotEntries += transaction.kvp.slots.sorted { $0.key < $1.key }
        block += slotsBlock(slotEntries, container: "trn:slots", indent: "  ")
        block += "  <trn:splits>\n"
        for split in transaction.splits {
            block += splitBlock(split, currencyFraction: transaction.currency.smallestFraction,
                                lotGUID: lotBySplit[split.guid])
        }
        block += "  </trn:splits>\n"
        block += "</gnc:transaction>\n"
        return block
    }

    private static func splitBlock(_ split: Split, currencyFraction: Int,
                                   lotGUID: GncGUID? = nil) -> String {
        let quantityFraction = split.account?.commodity.smallestFraction ?? currencyFraction
        var block = "    <trn:split>\n"
        block += "      <split:id type=\"guid\">\(split.guid.hexString)</split:id>\n"
        if !split.memo.isEmpty {
            block += "      <split:memo>\(escape(split.memo))</split:memo>\n"
        }
        if !split.action.isEmpty {
            block += "      <split:action>\(escape(split.action))</split:action>\n"
        }
        block += "      <split:reconciled-state>\(split.reconcileState.rawValue)</split:reconciled-state>\n"
        if let reconcileDate = split.reconcileDate {
            block += "      <split:reconcile-date><ts:date>\(GnuCashDate.format(reconcileDate))</ts:date></split:reconcile-date>\n"
        }
        block += "      <split:value>\(rational(split.value, fallbackFraction: currencyFraction))</split:value>\n"
        block += "      <split:quantity>\(rational(split.quantity, fallbackFraction: quantityFraction))</split:quantity>\n"
        if let account = split.account {
            block += "      <split:account type=\"guid\">\(account.guid.hexString)</split:account>\n"
        }
        if let lotGUID {
            block += "      <split:lot type=\"guid\">\(lotGUID.hexString)</split:lot>\n"
        }
        block += slotsBlock(split.kvp.slots.sorted { $0.key < $1.key },
                            container: "split:slots", indent: "      ")
        block += "    </trn:split>\n"
        return block
    }

    /// Emits a `<…:slots>` container for the given entries (sorted by the
    /// caller for deterministic output), or nothing when empty.
    static func slotsBlock(_ entries: [(String, KvpValue)],
                                   container: String, indent: String) -> String {
        guard !entries.isEmpty else { return "" }
        var block = "\(indent)<\(container)>\n"
        for (key, value) in entries {
            block += slotXML(key: key, value: value, indent: indent + "  ")
        }
        block += "\(indent)</\(container)>\n"
        return block
    }

    private static func slotXML(key: String, value: KvpValue, indent: String) -> String {
        var block = "\(indent)<slot>\n"
        block += "\(indent)  <slot:key>\(escape(key))</slot:key>\n"
        block += slotValueXML(value, indent: indent + "  ")
        block += "\(indent)</slot>\n"
        return block
    }

    private static func slotValueXML(_ value: KvpValue, indent: String) -> String {
        switch value {
        case .string(let text):
            return "\(indent)<slot:value type=\"string\">\(escape(text))</slot:value>\n"
        case .int64(let number):
            return "\(indent)<slot:value type=\"integer\">\(number)</slot:value>\n"
        case .double(let number):
            return "\(indent)<slot:value type=\"double\">\(number)</slot:value>\n"
        case .numeric(let number):
            return "\(indent)<slot:value type=\"numeric\">\(rational(number, fallbackFraction: 1_000_000))</slot:value>\n"
        case .guid(let guid):
            return "\(indent)<slot:value type=\"guid\">\(guid.hexString)</slot:value>\n"
        case .date(let date):
            // Day-only dates keep GnuCash's `gdate` form; date-times need
            // a `timespec` to survive with their time component.
            if GnuCashDate.isDayOnly(date) {
                return "\(indent)<slot:value type=\"gdate\"><gdate>\(GnuCashDate.formatDayOnly(date))</gdate></slot:value>\n"
            }
            return "\(indent)<slot:value type=\"timespec\"><ts:date>\(GnuCashDate.format(date))</ts:date></slot:value>\n"
        case .frame(let frame):
            var block = "\(indent)<slot:value type=\"frame\">\n"
            for (key, child) in frame.slots.sorted(by: { $0.key < $1.key }) {
                block += slotXML(key: key, value: child, indent: indent + "  ")
            }
            block += "\(indent)</slot:value>\n"
            return block
        case .list(let values):
            // GnuCash writes list elements as bare, keyless <slot:value> nodes
            // (no <slot> wrapper) — its reader keys off each child's type=
            // attribute (sixtp-dom-generators.cpp add_kvp_value_node).
            var block = "\(indent)<slot:value type=\"list\">\n"
            for child in values {
                block += slotValueXML(child, indent: indent + "  ")
            }
            block += "\(indent)</slot:value>\n"
            return block
        }
    }

    // MARK: Helpers

    static func namespace(_ namespace: CommodityNamespace) -> String {
        switch namespace {
        case .currency: return "CURRENCY"
        case .security(let name): return name
        case .other(let name): return name
        }
    }

    /// Formats a decimal as an **exact** GnuCash rational `num/denom` with a
    /// power-of-ten denominator, so no precision is lost (stock prices and
    /// quantities routinely carry more decimals than the currency fraction).
    /// A value that can't be represented in Int64 falls back to rounding at
    /// `fallbackFraction` (the commodity SCU).
    static func rational(_ value: Decimal, fallbackFraction: Int) -> String {
        var scaled = value
        var denominator: Int64 = 1
        while true {
            var rounded = Decimal()
            var candidate = scaled
            NSDecimalRound(&rounded, &candidate, 0, .plain)
            if rounded == scaled,
               abs(NSDecimalNumber(decimal: scaled).doubleValue) < 9.0e18 {
                return "\(NSDecimalNumber(decimal: scaled).int64Value)/\(denominator)"
            }
            guard denominator <= Int64.max / 10 else { break }
            scaled *= 10
            denominator *= 10
        }
        // Non-terminating decimal — typically an FX cross-rate that entered
        // as an odd rational (e.g. 71211/46999). Recover an equivalent
        // integer rational so a re-import divides back to the same Decimal.
        if let recovered = bestRational(value) { return recovered }
        var atFraction = value * Decimal(fallbackFraction)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &atFraction, 0, .plain)
        return "\(NSDecimalNumber(decimal: rounded).int64Value)/\(fallbackFraction)"
    }

    /// Continued-fraction search for an `Int64` rational whose `Decimal`
    /// division reproduces `value` exactly. Returns `nil` if none fits.
    private static func bestRational(_ value: Decimal) -> String? {
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        var x = magnitude
        var h0: Int64 = 0, h1: Int64 = 1
        var k0: Int64 = 1, k1: Int64 = 0
        for _ in 0..<64 {
            var whole = Decimal()
            var work = x
            NSDecimalRound(&whole, &work, 0, .down)
            guard NSDecimalNumber(decimal: whole).doubleValue < 9.0e18 else { return nil }
            let a = NSDecimalNumber(decimal: whole).int64Value
            let (ah, overflowAH) = a.multipliedReportingOverflow(by: h1)
            let (h, overflowH) = ah.addingReportingOverflow(h0)
            let (ak, overflowAK) = a.multipliedReportingOverflow(by: k1)
            let (k, overflowK) = ak.addingReportingOverflow(k0)
            if overflowAH || overflowH || overflowAK || overflowK { return nil }
            (h0, h1) = (h1, h)
            (k0, k1) = (k1, k)
            if k1 > 0, Decimal(h1) / Decimal(k1) == magnitude {
                return "\(sign)\(h1)/\(k1)"
            }
            let fraction = x - whole
            if fraction == 0 { return nil }
            x = 1 / fraction
        }
        return nil
    }

    /// Escapes element text content. Only `& < >` need escaping there —
    /// quotes and apostrophes stay literal, matching GnuCash's own output
    /// (we never emit user text inside attribute values).
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
    }
}
