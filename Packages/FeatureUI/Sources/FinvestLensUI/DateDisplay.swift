//
//  DateDisplay.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The user's date-format preference (Settings ▸ General ▸ Dates): just the
//  component order — Australian D/M/Y, US M.D.Y, or Japanese Y-M-D. The app
//  chooses how much to write out per context: `short` (numeric) in dense
//  tables, `long` (month spelled out) in labels and documents, `full` (with
//  weekday) where a single date headlines and space allows, and compact
//  partials (`monthDay`, `monthYear`) where the year or day is implied.
//  Published through the environment by ``AppearanceModifier`` so every
//  displayed date re-renders when the preference changes; non-view contexts
//  (report documents, printing, the clipboard) read ``AppDateFormat/current``.
//

import Foundation
import SwiftUI

/// Which component comes first — the regional convention. The only choice the
/// user makes; styles are picked by context.
public enum DateOrder: String, CaseIterable, Identifiable, Sendable {
    case dmy   // 16/12/2025 — Australian
    case mdy   // 12.16.2025 — United States
    case ymd   // 2025-12-16 — Japanese

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dmy: "D/M/Y — Australian"
        case .mdy: "M.D.Y — United States"
        case .ymd: "Y-M-D — Japanese"
        }
    }
}

/// The resolved date-format preference. Value type so it can sit in the
/// environment and equality-drive re-renders.
public struct AppDateFormat: Equatable, Sendable {
    public var order: DateOrder

    public init(order: DateOrder = .dmy) {
        self.order = order
    }

    // MARK: Preference storage

    public static let orderKey = "finvestlens.dateOrder"

    /// The stored preference — for contexts outside the view tree (report
    /// documents, check printing, pasteboard text). Views should read
    /// `\.appDateFormat` instead so they re-render on change.
    public static var current: AppDateFormat {
        AppDateFormat(order: UserDefaults.standard.string(forKey: orderKey)
            .flatMap(DateOrder.init(rawValue:)) ?? .dmy)
    }

    // MARK: Formatting

    /// Numeric — for dense tables and lists: 16/12/2025, 12.16.2025, 2025-12-16.
    public func short(_ date: Date) -> String {
        let pattern = switch order {
        case .dmy: "d/M/yyyy"
        case .mdy: "M.d.yyyy"
        case .ymd: "yyyy-MM-dd"
        }
        return Self.formatted(date, pattern: pattern)
    }

    /// Month spelled out — for labels, sentences and documents:
    /// 16 December 2025, December 16, 2025, 2025 December 16.
    public func long(_ date: Date) -> String {
        let pattern = switch order {
        case .dmy: "d MMMM yyyy"
        case .mdy: "MMMM d, yyyy"
        case .ymd: "yyyy MMMM d"
        }
        return Self.formatted(date, pattern: pattern)
    }

    /// Weekday and month spelled out — where one date headlines and there is
    /// room: Tuesday, 16 December 2025 …
    public func full(_ date: Date) -> String {
        let pattern = switch order {
        case .dmy: "EEEE, d MMMM yyyy"
        case .mdy: "EEEE, MMMM d, yyyy"
        case .ymd: "EEEE, yyyy MMMM d"
        }
        return Self.formatted(date, pattern: pattern)
    }

    /// A compact month-and-day (abbreviated month), ordered per the preference —
    /// for tight dashboard rows where the year is implied.
    public func monthDay(_ date: Date) -> String {
        Self.formatted(date, pattern: order == .dmy ? "d MMM" : "MMM d")
    }

    /// A month-and-year (abbreviated month), ordered per the preference — for
    /// report columns labelled by month.
    public func monthYear(_ date: Date) -> String {
        Self.formatted(date, pattern: order == .ymd ? "yyyy MMM" : "MMM yyyy")
    }

    // MARK: Formatter cache

    /// One configured `DateFormatter` per pattern. Formatters are expensive to
    /// build and (post-configuration) safe to share; the lock guards the
    /// dictionary itself.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    private static func formatted(_ date: Date, pattern: String) -> String {
        cacheLock.lock()
        let formatter: DateFormatter
        if let hit = cache[pattern] {
            formatter = hit
        } else {
            formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = pattern
            cache[pattern] = formatter
        }
        cacheLock.unlock()
        return formatter.string(from: date)
    }
}

/// Environment plumbing (mirrors `\.appFontScale`).
private struct AppDateFormatKey: EnvironmentKey {
    static let defaultValue = AppDateFormat()
}

public extension EnvironmentValues {
    var appDateFormat: AppDateFormat {
        get { self[AppDateFormatKey.self] }
        set { self[AppDateFormatKey.self] = newValue }
    }
}
