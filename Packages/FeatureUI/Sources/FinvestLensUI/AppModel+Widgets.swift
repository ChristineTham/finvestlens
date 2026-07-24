//
//  AppModel+Widgets.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports
import FinvestLensShared
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
extension AppModel {

    /// Publishes the App Group snapshot the WidgetKit and Quick Look extensions
    /// read, and reconciles alert notifications (`FR-PLT-03`, `FR-PLAN-05`).
    ///
    /// Built from the **live in-memory book** — never re-reading the document —
    /// so it is cheap enough to call on save / open / close. It is deliberately
    /// *not* wired into `refreshAll()` (every edit), because the widget only
    /// needs the persisted picture.
    public func publishWidgetData() {
        // Test processes have no app bundle: WidgetKit/UNUserNotificationCenter
        // throw NSExceptions there ("bundleProxyForCurrentProcess is nil") and
        // kill the whole suite mid-run. A missing bundle identifier is the
        // reliable tell across XCTest and swift-testing runners.
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard let book else {
            WidgetSnapshot.placeholder.write()
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            Task { await AlertNotificationScheduler.cancelAll() }
            return
        }
        let currency = reportCurrency
        let now = Date()

        let netWorth = FinancialReports.netWorthSeries(book, dates: [now], currency: currency)
            .last?.netWorth ?? 0

        let bills = FinancialReports.billReminders(
            book, scheduled: scheduledTransactions,
            from: now.addingTimeInterval(-30 * 86_400),
            to: now.addingTimeInterval(60 * 86_400), asOf: now
        ).filter { $0.status != .paid }
        let billsLine: String
        if bills.isEmpty {
            billsLine = "No upcoming bills"
        } else {
            let total = bills.reduce(Decimal(0)) { $0 + $1.amount }
            billsLine = "\(bills.count) bill\(bills.count == 1 ? "" : "s") due · \(AmountFormat.string(total, code: currency.mnemonic))"
        }

        // Computed once on the main actor and reused for both the snapshot and
        // the notifications, so the non-`Sendable` book never crosses actors.
        let allAlerts = alerts(asOf: now)
        let alertItems = allAlerts.prefix(5).map {
            WidgetSnapshot.Alert(title: $0.title, message: $0.message, severity: $0.severity.rawValue)
        }

        let name = documentURL?.deletingPathExtension().lastPathComponent ?? "FinvestLens"

        WidgetSnapshot(
            bookName: name,
            netWorth: AmountFormat.string(netWorth, code: currency.mnemonic),
            upcomingBills: billsLine,
            alerts: Array(alertItems),
            updatedAt: now
        ).write()

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif

        Task { await AlertNotificationScheduler.sync(alerts: allAlerts, asOf: now) }
    }
}
