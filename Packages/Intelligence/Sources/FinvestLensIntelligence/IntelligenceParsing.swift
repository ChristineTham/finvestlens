//
//  IntelligenceParsing.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Tolerant parsing of model-generated values.
///
/// Guided generation constrains *shape*, not *content*: amounts arrive as
/// strings that may carry currency symbols, thousands separators, or
/// parenthesised negatives, and dates arrive as `yyyy-MM-dd` (requested in
/// every prompt) but occasionally degrade to other unambiguous forms.
public enum IntelligenceParsing {

    /// Parses a monetary string: `"$1,234.56"`, `"(45.20)"`, `"-45.20"`, `"CR 12.00"`.
    public static func amount(_ raw: String) -> Decimal? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        if text.uppercased().hasSuffix("DR") || text.uppercased().hasPrefix("DR") {
            negative = true
        }
        text = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        // A lone trailing minus (European style "45.20-") still means negative.
        if text.hasSuffix("-") {
            negative = true
            text = String(text.dropLast())
        }
        guard let value = Decimal(string: text), !text.isEmpty else { return nil }
        return negative && value > 0 ? -value : value
    }

    /// Parses a model-generated date, preferring ISO `yyyy-MM-dd`.
    public static func date(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd", "yyyy/MM/dd", "dd/MM/yyyy", "d MMMM yyyy", "MMMM d, yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: String(text.prefix(24))) {
                return date
            }
        }
        return nil
    }
}
