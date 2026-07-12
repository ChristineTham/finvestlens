//
//  OFXImport.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Parses OFX / QFX files (`FR-XIO-02`).
///
/// Handles both **OFX v1 (SGML)** — where value-only tags have no closing tag —
/// and **OFX v2 (XML)** with a single tolerant scanner: for each field tag we
/// read the value up to the next `<`, which captures the value in both formats
/// (Architecture §5.8a). Extracts `<STMTTRN>` entries from bank, card, and
/// investment statements.
public enum OFXImporter {

    public static func parse(_ data: Data) -> [StagedTransaction] {
        parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) -> [StagedTransaction] {
        // Split on the transaction marker; the first chunk is the header/preamble.
        let chunks = text.components(separatedBy: "<STMTTRN>").dropFirst()
        var result: [StagedTransaction] = []

        for chunk in chunks {
            // Bound the chunk at the closing tag if present (v2) or the next
            // statement boundary (v1).
            let body = chunk.components(separatedBy: "</STMTTRN>").first ?? chunk

            guard let posted = value("DTPOSTED", in: body),
                  let date = parseDate(posted),
                  let amountText = value("TRNAMT", in: body),
                  let amount = ImportParsing.amount(amountText)
            else { continue }

            result.append(StagedTransaction(
                date: date,
                amount: amount,
                payee: value("NAME", in: body) ?? value("PAYEE", in: body) ?? "",
                memo: value("MEMO", in: body) ?? "",
                reference: value("FITID", in: body) ?? ""
            ))
        }
        return result
    }

    /// Reads the value following `<TAG>` up to the next `<` — works for both
    /// unclosed SGML tags and closed XML tags.
    private static func value(_ tag: String, in body: String) -> String? {
        guard let range = body.range(of: "<\(tag)>", options: .caseInsensitive) else { return nil }
        let after = body[range.upperBound...]
        let end = after.firstIndex(of: "<") ?? after.endIndex
        let value = String(after[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// OFX dates are `YYYYMMDD` optionally followed by time/zone; take the date.
    private static func parseDate(_ raw: String) -> Date? {
        let digits = raw.prefix { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: String(digits.prefix(8)))
    }
}
