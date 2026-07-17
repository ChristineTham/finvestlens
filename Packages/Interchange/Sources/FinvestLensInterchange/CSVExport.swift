//
//  CSVExport.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Exports the book to CSV (`FR-XIO-06`), mirroring GnuCash's CSV exporters
/// (`csv-tree-export.cpp`, `csv-transactions-export.cpp`) closely enough that the
/// files are recognisable to a GnuCash user and re-importable: the account tree,
/// the transactions (one row per split, GnuCash's "full" layout), and the price
/// database.
public enum CSVExporter {

    // MARK: Account tree

    /// Columns mirror GnuCash `csv-tree-export.cpp`.
    public static func accounts(_ book: Book) -> String {
        var out = row([
            "Type", "Full Account Name", "Account Name", "Account Code",
            "Description", "Account Color", "Notes", "Symbol", "Namespace",
            "Hidden", "Tax Info", "Placeholder",
        ])
        for account in book.accounts.sorted(by: { $0.fullName < $1.fullName }) where account.type != .root {
            out += row([
                account.type.rawValue,
                account.fullName,
                account.name,
                account.code,
                account.accountDescription,
                account.color ?? "",
                account.notes,
                account.commodity.mnemonic,
                GnuCashXMLExporter.namespace(account.commodity.namespace),
                account.isHidden ? "T" : "F",
                account.taxRelated ? "T" : "F",
                account.isPlaceholder ? "T" : "F",
            ])
        }
        return out
    }

    // MARK: Transactions (one row per split — GnuCash "full" layout)

    public static func transactions(_ book: Book) -> String {
        var out = row([
            "Date", "Transaction ID", "Number", "Description", "Notes",
            "Commodity/Currency", "Action", "Memo", "Full Account Name",
            "Amount Num.", "Value Num.", "Reconcile", "Reconcile Date", "Rate/Price",
        ])
        let txns = book.transactions.sorted(by: Self.txnOrder)
        for txn in txns {
            for split in txn.splits {
                // Rate/price = |value ÷ quantity| when the split moves a
                // non-currency quantity (GnuCash's Rate/Price column).
                let rate: String
                if split.quantity != 0, split.quantity != split.value {
                    rate = num(abs(split.value / split.quantity))
                } else {
                    rate = ""
                }
                out += row([
                    date(txn.datePosted),
                    txn.guid.hexString,
                    txn.number,
                    txn.transactionDescription,
                    txn.notes,
                    "\(GnuCashXMLExporter.namespace(txn.currency.namespace))::\(txn.currency.mnemonic)",
                    split.action,
                    split.memo,
                    split.account?.fullName ?? "",
                    num(split.quantity),
                    num(split.value),
                    split.reconcileState.rawValue,
                    split.reconcileDate.map(date) ?? "",
                    rate,
                ])
            }
        }
        return out
    }

    // MARK: Prices

    public static func prices(_ book: Book) -> String {
        var out = row(["Date", "Namespace", "Commodity", "Currency", "Price", "Source", "Type"])
        let prices = book.prices.sorted(by: Self.priceOrder)
        for price in prices {
            out += row([
                date(price.date),
                GnuCashXMLExporter.namespace(price.commodity.namespace),
                price.commodity.mnemonic,
                price.currency.mnemonic,
                num(price.value),
                price.source,
                price.type,
            ])
        }
        return out
    }

    // MARK: - Formatting helpers

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 2      // clean money columns (100 → "100.00")
        f.maximumFractionDigits = 8      // keep share/price precision
        return f
    }()

    /// A locale-independent fixed-decimal string (`.` separator, no grouping) —
    /// machine-readable and re-importable, unlike GnuCash's symbol-bearing columns.
    static func num(_ value: Decimal) -> String {
        numberFormatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    /// Stable ordering: by posting date, then GUID as a tiebreak.
    static func txnOrder(_ a: Transaction, _ b: Transaction) -> Bool {
        if a.datePosted != b.datePosted { return a.datePosted < b.datePosted }
        return a.guid.hexString < b.guid.hexString
    }

    static func priceOrder(_ a: Price, _ b: Price) -> Bool {
        if a.date != b.date { return a.date < b.date }
        return a.commodity.mnemonic < b.commodity.mnemonic
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// RFC-4180 row: quote any field containing a comma, quote, or newline.
    static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\n"
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
