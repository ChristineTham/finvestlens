//
//  CSVImport.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A minimal RFC-4180 CSV tokenizer (handles quoting, escaped quotes, and
/// CRLF/LF line endings).
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false
                } else {
                    field.append(c)
                }
                i += 1
            } else {
                switch c {
                case "\"": inQuotes = true; i += 1
                case ",": endField(); i += 1
                case "\r": i += 1
                case "\n": endRow(); i += 1
                default: field.append(c); i += 1
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

/// Maps CSV columns (0-based) to transaction fields.
public struct CSVColumnMapping: Sendable {
    public var date: Int
    /// A single signed-amount column, or use ``debit``/``credit``.
    public var amount: Int?
    public var debit: Int?
    public var credit: Int?
    public var payee: Int?
    public var memo: Int?
    public var reference: Int?
    public var dateFormat: String
    public var hasHeader: Bool

    public init(date: Int, amount: Int? = nil, debit: Int? = nil, credit: Int? = nil,
                payee: Int? = nil, memo: Int? = nil, reference: Int? = nil,
                dateFormat: String = "yyyy-MM-dd", hasHeader: Bool = true) {
        self.date = date
        self.amount = amount
        self.debit = debit
        self.credit = credit
        self.payee = payee
        self.memo = memo
        self.reference = reference
        self.dateFormat = dateFormat
        self.hasHeader = hasHeader
    }
}

/// Parses CSV bank exports into ``StagedTransaction`` rows using a column map
/// (`FR-XIO-03`).
public enum CSVTransactionImporter {

    public static func parse(_ data: Data, mapping: CSVColumnMapping) -> [StagedTransaction] {
        parse(String(decoding: data, as: UTF8.self), mapping: mapping)
    }

    public static func parse(_ text: String, mapping: CSVColumnMapping) -> [StagedTransaction] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = mapping.dateFormat

        var rows = CSV.parse(text)
        if mapping.hasHeader, !rows.isEmpty { rows.removeFirst() }

        var result: [StagedTransaction] = []
        for row in rows {
            func field(_ index: Int?) -> String? {
                guard let index, index >= 0, index < row.count else { return nil }
                return row[index]
            }
            guard let dateText = field(mapping.date),
                  let date = formatter.date(from: dateText.trimmingCharacters(in: .whitespaces))
            else { continue }

            let amount: Decimal
            if let single = field(mapping.amount).flatMap(ImportParsing.amount) {
                amount = single
            } else {
                let debit = field(mapping.debit).flatMap(ImportParsing.amount) ?? 0
                let credit = field(mapping.credit).flatMap(ImportParsing.amount) ?? 0
                amount = credit - abs(debit)
            }

            result.append(StagedTransaction(
                date: date,
                amount: amount,
                payee: field(mapping.payee) ?? "",
                memo: field(mapping.memo) ?? "",
                reference: field(mapping.reference) ?? ""
            ))
        }
        return result
    }
}

/// One price row parsed from a CSV file, before it is resolved against the
/// book's commodities and added to the price DB (`FR-XIO-03`).
public struct StagedPrice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var date: Date
    /// Mnemonic/symbol of the thing being priced (e.g. "CBA").
    public var commoditySymbol: String
    /// Mnemonic of the currency the price is expressed in (e.g. "AUD"); may be
    /// blank if the file omits it (the caller supplies a default).
    public var currencyCode: String
    public var value: Decimal

    public init(id: UUID = UUID(), date: Date, commoditySymbol: String,
                currencyCode: String, value: Decimal) {
        self.id = id
        self.date = date
        self.commoditySymbol = commoditySymbol
        self.currencyCode = currencyCode
        self.value = value
    }
}

/// Maps CSV columns (0-based) to price fields.
public struct CSVPriceColumnMapping: Sendable {
    public var date: Int
    public var commodity: Int
    public var price: Int
    public var currency: Int?
    public var dateFormat: String
    public var hasHeader: Bool

    public init(date: Int, commodity: Int, price: Int, currency: Int? = nil,
                dateFormat: String = "yyyy-MM-dd", hasHeader: Bool = true) {
        self.date = date
        self.commodity = commodity
        self.price = price
        self.currency = currency
        self.dateFormat = dateFormat
        self.hasHeader = hasHeader
    }
}

/// Parses a CSV of commodity prices into ``StagedPrice`` rows (`FR-XIO-03`),
/// re-importing what ``CSVExporter/prices(_:)`` writes and typical broker/index
/// price exports.
public enum CSVPriceImporter {

    public static func parse(_ data: Data, mapping: CSVPriceColumnMapping) -> [StagedPrice] {
        parse(String(decoding: data, as: UTF8.self), mapping: mapping)
    }

    public static func parse(_ text: String, mapping: CSVPriceColumnMapping) -> [StagedPrice] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = mapping.dateFormat

        var rows = CSV.parse(text)
        if mapping.hasHeader, !rows.isEmpty { rows.removeFirst() }

        var result: [StagedPrice] = []
        for row in rows {
            func field(_ index: Int?) -> String? {
                guard let index, index >= 0, index < row.count else { return nil }
                return row[index]
            }
            guard let dateText = field(mapping.date),
                  let date = formatter.date(from: dateText.trimmingCharacters(in: .whitespaces)),
                  let symbol = field(mapping.commodity)?.trimmingCharacters(in: .whitespaces), !symbol.isEmpty,
                  let value = field(mapping.price).flatMap(ImportParsing.amount), value > 0
            else { continue }

            result.append(StagedPrice(
                date: date,
                commoditySymbol: symbol,
                currencyCode: field(mapping.currency)?.trimmingCharacters(in: .whitespaces) ?? "",
                value: value
            ))
        }
        return result
    }

    /// Parses a CSV of prices by matching the **header row** to common column
    /// names — so the UI can import without a column-mapping dialog. Recognises
    /// what ``CSVExporter/prices(_:)`` writes and typical broker/index exports.
    /// Returns `nil` if the required date/commodity/price columns can't be found.
    public static func parseAutodetect(_ text: String, dateFormat: String = "yyyy-MM-dd") -> [StagedPrice]? {
        let rows = CSV.parse(text)
        guard let header = rows.first else { return nil }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        func column(_ candidates: [String]) -> Int? {
            names.firstIndex { candidates.contains($0) }
        }
        guard let date = column(["date", "trade date", "day"]),
              let commodity = column(["commodity", "symbol", "ticker", "security", "code", "name"]),
              let price = column(["price", "close", "value", "adj close", "adjusted close", "last"])
        else { return nil }
        let currency = column(["currency", "ccy"])

        return parse(text, mapping: CSVPriceColumnMapping(
            date: date, commodity: commodity, price: price, currency: currency,
            dateFormat: dateFormat, hasHeader: true))
    }
}
