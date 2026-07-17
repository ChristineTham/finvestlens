//
//  WidgetSnapshot.swift
//  FinvestLens — Shared
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A small, self-contained snapshot the app publishes to the App Group
/// container after each refresh, and the WidgetKit / Quick Look extensions
/// read. It carries pre-formatted display strings so an extension never has to
/// open the book (which it cannot: a separate, memory-limited process without
/// access to the user-selected document).
public struct WidgetSnapshot: Codable, Hashable, Sendable {

    /// One proactive alert, flattened for display (mirrors `FinancialAlert`).
    public struct Alert: Codable, Hashable, Sendable {
        public var title: String
        public var message: String
        /// 0 = info, 1 = warning, 2 = critical (mirrors `AlertSeverity`).
        public var severity: Int

        public init(title: String, message: String, severity: Int) {
            self.title = title
            self.message = message
            self.severity = severity
        }
    }

    /// The book this snapshot was taken from (for the widget's footer / staleness).
    public var bookName: String
    /// Pre-formatted net worth, e.g. "$1,234,567.00".
    public var netWorth: String
    /// Pre-formatted upcoming-bills line, e.g. "3 bills due · $420.00".
    public var upcomingBills: String
    /// Top alerts, most-severe first.
    public var alerts: [Alert]
    /// When the app last published this snapshot.
    public var updatedAt: Date

    public init(
        bookName: String,
        netWorth: String,
        upcomingBills: String,
        alerts: [Alert],
        updatedAt: Date
    ) {
        self.bookName = bookName
        self.netWorth = netWorth
        self.upcomingBills = upcomingBills
        self.alerts = alerts
        self.updatedAt = updatedAt
    }

    /// A neutral placeholder used for the widget gallery and before the app has
    /// published anything.
    public static let placeholder = WidgetSnapshot(
        bookName: "FinvestLens",
        netWorth: "$0.00",
        upcomingBills: "No upcoming bills",
        alerts: [],
        updatedAt: Date(timeIntervalSinceReferenceDate: 0)
    )

    // MARK: - App Group persistence

    /// Writes the snapshot to the shared container. No-op (returns `false`) when
    /// the App Group is not yet provisioned.
    @discardableResult
    public func write() -> Bool {
        guard let url = SharedAppGroup.snapshotURL else { return false }
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Reads the latest snapshot from the shared container, or `nil` if none has
    /// been published (or the App Group is unavailable).
    public static func read() -> WidgetSnapshot? {
        guard let url = SharedAppGroup.snapshotURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
