//
//  DateDisplay.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The user's date-format preference (Settings ▸ General ▸ Dates): an ordering
//  (Australian D/M/Y, US M.D.Y, Japanese Y-M-D) crossed with a style (short
//  numeric, long with the month spelled out, full with the weekday). Published
//  through the environment by ``AppearanceModifier`` so every displayed date
//  re-renders when the preference changes; non-view contexts (report documents,
//  printing, the clipboard) read ``AppDateFormat/current``.
//

import Foundation
import SwiftUI

/// Which component comes first — the regional convention.
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

/// How much of the date is written out.
public enum DateDisplayStyle: String, CaseIterable, Identifiable, Sendable {
    /// Numeric: 16/12/2025, 12.16.2025, 2025-12-16.
    case short
    /// Month spelled out: 16 December 2025, December 16, 2025, 2025 December 16.
    case long
    /// Weekday and month spelled out: Tuesday, 16 December 2025 …
    case full

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .short: "Short"
        case .long: "Long"
        case .full: "Full (with weekday)"
        }
    }
}

/// A resolved date-format preference. Value type so it can sit in the
/// environment and equality-drive re-renders.
public struct AppDateFormat: Equatable, Sendable {
    public var order: DateOrder
    public var style: DateDisplayStyle

    public init(order: DateOrder = .dmy, style: DateDisplayStyle = .short) {
        self.order = order
        self.style = style
    }

    // MARK: Preference storage

    public static let orderKey = "finvestlens.dateOrder"
    public static let styleKey = "finvestlens.dateStyle"

    /// The stored preference — for contexts outside the view tree (report
    /// documents, check printing, pasteboard text). Views should read
    /// `\.appDateFormat` instead so they re-render on change.
    public static var current: AppDateFormat {
        let defaults = UserDefaults.standard
        return AppDateFormat(
            order: defaults.string(forKey: orderKey).flatMap(DateOrder.init(rawValue:)) ?? .dmy,
            style: defaults.string(forKey: styleKey).flatMap(DateDisplayStyle.init(rawValue:)) ?? .short)
    }

    // MARK: Formatting

    /// The full date in the chosen order and style.
    public func string(_ date: Date) -> String {
        Self.formatted(date, pattern: Self.pattern(order: order, style: style))
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

    static func pattern(order: DateOrder, style: DateDisplayStyle) -> String {
        switch (order, style) {
        case (.dmy, .short): "d/M/yyyy"
        case (.dmy, .long): "d MMMM yyyy"
        case (.dmy, .full): "EEEE, d MMMM yyyy"
        case (.mdy, .short): "M.d.yyyy"
        case (.mdy, .long): "MMMM d, yyyy"
        case (.mdy, .full): "EEEE, MMMM d, yyyy"
        case (.ymd, .short): "yyyy-MM-dd"
        case (.ymd, .long): "yyyy MMMM d"
        case (.ymd, .full): "EEEE, yyyy MMMM d"
        }
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
