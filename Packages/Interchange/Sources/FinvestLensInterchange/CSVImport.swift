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
