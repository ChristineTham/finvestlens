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
/// exact GnuCash rationals (`num/denom`), so no precision is lost. Prices,
/// budgets, scheduled and business objects are not yet written (P5+).
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
             xmlns:ts="http://www.gnucash.org/XML/ts">
        <gnc:count-data cd:type="book">1</gnc:count-data>
        <gnc:book version="2.0.0">
        <book:id type="guid">\(book.guid.hexString)</book:id>

        """

        let accounts = [book.rootAccount] + book.rootAccount.descendants
        out += "<gnc:count-data cd:type=\"commodity\">\(book.commodities.count)</gnc:count-data>\n"
        out += "<gnc:count-data cd:type=\"account\">\(accounts.count)</gnc:count-data>\n"
        out += "<gnc:count-data cd:type=\"transaction\">\(book.transactions.count)</gnc:count-data>\n"

        for commodity in book.commodities {
            out += commodityBlock(commodity)
        }
        if !book.prices.isEmpty {
            out += priceDBBlock(book.prices)
        }
        for account in accounts {
            out += accountBlock(account)
        }
        for transaction in book.transactions {
            out += transactionBlock(transaction)
        }

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
        if !commodity.fullName.isEmpty && commodity.fullName != commodity.mnemonic {
            block += "  <cmdty:name>\(escape(commodity.fullName))</cmdty:name>\n"
        }
        block += "  <cmdty:fraction>\(commodity.smallestFraction)</cmdty:fraction>\n"
        block += "</gnc:commodity>\n"
        return block
    }

    private static func accountBlock(_ account: Account) -> String {
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
        if account.isPlaceholder || account.isHidden {
            block += "  <act:slots>\n"
            if account.isPlaceholder { block += boolSlot("placeholder") }
            if account.isHidden { block += boolSlot("hidden") }
            block += "  </act:slots>\n"
        }
        if let parent = account.parent {
            block += "  <act:parent type=\"guid\">\(parent.guid.hexString)</act:parent>\n"
        }
        block += "</gnc:account>\n"
        return block
    }

    private static func transactionBlock(_ transaction: Transaction) -> String {
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
        // Document link (GnuCash transaction association, FR-AI-08).
        if let link = transaction.documentLink {
            block += "  <trn:slots>\n"
            block += "    <slot>\n"
            block += "      <slot:key>assoc_uri</slot:key>\n"
            block += "      <slot:value type=\"string\">\(escape(link))</slot:value>\n"
            block += "    </slot>\n"
            block += "  </trn:slots>\n"
        }
        block += "  <trn:splits>\n"
        for split in transaction.splits {
            block += splitBlock(split, currencyFraction: transaction.currency.smallestFraction)
        }
        block += "  </trn:splits>\n"
        block += "</gnc:transaction>\n"
        return block
    }

    private static func splitBlock(_ split: Split, currencyFraction: Int) -> String {
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
        block += "      <split:value>\(rational(split.value, fallbackFraction: currencyFraction))</split:value>\n"
        block += "      <split:quantity>\(rational(split.quantity, fallbackFraction: quantityFraction))</split:quantity>\n"
        if let account = split.account {
            block += "      <split:account type=\"guid\">\(account.guid.hexString)</split:account>\n"
        }
        block += "    </trn:split>\n"
        return block
    }

    private static func boolSlot(_ key: String) -> String {
        """
            <slot>
              <slot:key>\(key)</slot:key>
              <slot:value type="string">true</slot:value>
            </slot>

        """
    }

    // MARK: Helpers

    private static func namespace(_ namespace: CommodityNamespace) -> String {
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
    private static func rational(_ value: Decimal, fallbackFraction: Int) -> String {
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

    private static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }
}
