//
//  QIFImport.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Parses Quicken Interchange Format (QIF) files (`FR-XIO-01`).
///
/// QIF is line-oriented: a single-letter code begins each line, records end
/// with `^`, and `!Type:` headers introduce sections. Hand-written per
/// Architecture §5.8a (no Swift package exists).
public enum QIFImporter {

    /// Common QIF date encodings, tried in order. `''` is a literal apostrophe.
    static let dateFormats = [
        "MM/dd/yyyy", "M/d/yyyy", "dd/MM/yyyy", "d/M/yyyy",
        "MM/dd''yy", "M/d''yy", "yyyy-MM-dd",
    ]

    public static func parse(_ data: Data) -> [StagedTransaction] {
        parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) -> [StagedTransaction] {
        var result: [StagedTransaction] = []
        var date: Date?
        var amount: Decimal?
        var payee = "", memo = "", reference = "", category = ""

        func flush() {
            if let date, let amount {
                result.append(StagedTransaction(date: date, amount: amount, payee: payee,
                                                memo: memo, reference: reference, category: category))
            }
            date = nil; amount = nil; payee = ""; memo = ""; reference = ""; category = ""
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let code = line.first else { continue }
            let value = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            switch code {
            case "!": continue                          // section header
            case "^": flush()
            case "D": date = parseDate(value)
            case "T", "U": amount = ImportParsing.amount(value)
            case "P": payee = value
            case "M": memo = value
            case "N": reference = value
            case "L": category = value
            default: break
            }
        }
        flush()                                          // trailing record without ^
        return result
    }

    private static func parseDate(_ raw: String) -> Date? {
        let text = raw.replacingOccurrences(of: " ", with: "")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
