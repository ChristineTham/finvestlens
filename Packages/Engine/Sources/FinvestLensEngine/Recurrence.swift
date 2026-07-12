//
//  Recurrence.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The repetition unit of a ``Recurrence``.
public enum RecurrencePeriod: String, Codable, Sendable, CaseIterable {
    case daily
    case weekly
    case monthly
    case yearly
}

/// A repetition rule: every `interval` `period`s starting from `startDate`
/// (GnuCash's `Recurrence`).
public struct Recurrence: Codable, Hashable, Sendable {
    public var period: RecurrencePeriod
    /// Every N periods (1 = every period).
    public var interval: Int
    public var startDate: Date

    public init(period: RecurrencePeriod, interval: Int = 1, startDate: Date) {
        self.period = period
        self.interval = max(1, interval)
        self.startDate = startDate
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// Advances a date by one interval of this recurrence.
    public func advance(_ date: Date, calendar: Calendar? = nil) -> Date? {
        let cal = calendar ?? Self.utcCalendar
        var components = DateComponents()
        switch period {
        case .daily: components.day = interval
        case .weekly: components.day = 7 * interval
        case .monthly: components.month = interval
        case .yearly: components.year = interval
        }
        return cal.date(byAdding: components, to: date)
    }

    /// Occurrence dates strictly after `since` (exclusive) and on/before
    /// `through` (inclusive), anchored at ``startDate``.
    public func occurrences(since: Date?, through: Date,
                            limit: Int = 5000, calendar: Calendar? = nil) -> [Date] {
        guard startDate <= through else { return [] }
        let cal = calendar ?? Self.utcCalendar
        var result: [Date] = []
        var date = startDate
        var iterations = 0
        while date <= through, iterations < limit {
            if since == nil || date > since! {
                result.append(date)
            }
            guard let next = advance(date, calendar: cal) else { break }
            date = next
            iterations += 1
        }
        return result
    }

    /// The next occurrence strictly after `date`.
    public func next(after date: Date, calendar: Calendar? = nil) -> Date? {
        let cal = calendar ?? Self.utcCalendar
        var candidate = startDate
        var iterations = 0
        while candidate <= date, iterations < 100_000 {
            guard let next = advance(candidate, calendar: cal) else { return nil }
            candidate = next
            iterations += 1
        }
        return candidate > date ? candidate : nil
    }
}
