//
//  GnuCashDate.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Parses the date formats found in GnuCash XML.
///
/// `<trn:date-posted>` uses a `<ts:date>` like `2026-01-15 00:00:00 +0000`;
/// some fields use a plain `<gdate>` like `2026-01-15`.
enum GnuCashDate {

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Formats a date as a GnuCash `ts:date` string
    /// (e.g. `2026-01-15 00:00:00 +0000`).
    static func format(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    /// Formats a date as a GnuCash `gdate` (day-only, UTC) string.
    static func formatDayOnly(_ date: Date) -> String {
        dateOnlyFormatter.string(from: date)
    }

    /// `true` when the date is exactly midnight UTC — i.e. it carries no
    /// time-of-day and can be written as a `gdate` without loss.
    static func isDayOnly(_ date: Date) -> Bool {
        date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) == 0
    }

    /// Parses a `ts:date` / `gdate` string, tolerating both forms.
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = dateTimeFormatter.date(from: text) {
            return date
        }
        // Tolerate a colon in the timezone offset (e.g. "+00:00").
        let normalized = text.replacingOccurrences(
            of: #"([+-]\d{2}):(\d{2})$"#,
            with: "$1$2",
            options: .regularExpression
        )
        if let date = dateTimeFormatter.date(from: normalized) {
            return date
        }
        return dateOnlyFormatter.date(from: text)
    }
}
