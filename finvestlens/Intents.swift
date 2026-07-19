//
//  Intents.swift
//  finvestlens
//
//  This file is part of FinvestLens.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppIntents
import FinvestLensUI

/// Reports the current net worth (`FR-PLT-03`).
struct NetWorthIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Net Worth"
    static let description = IntentDescription("Reports your current net worth from your FinvestLens book.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: IntentSupport.netWorthSummary()))
    }
}

/// Reports upcoming/overdue bills.
struct UpcomingBillsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Upcoming Bills"
    static let description = IntentDescription("Summarises your upcoming and overdue bills.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: IntentSupport.upcomingBillsSummary()))
    }
}

/// Reports current financial alerts.
struct FinancialAlertsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Financial Alerts"
    static let description = IntentDescription("Reports bills due, over-budget spending and other alerts.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: IntentSupport.alertsSummary()))
    }
}

/// Exposes the intents to Shortcuts / Spotlight / Siri.
struct FinvestLensShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NetWorthIntent(), phrases: [
            "Show my net worth in \(.applicationName)",
            "\(.applicationName) net worth",
        ], shortTitle: "Net Worth", systemImageName: "chart.line.uptrend.xyaxis")
        AppShortcut(intent: UpcomingBillsIntent(), phrases: [
            "Show my upcoming bills in \(.applicationName)",
            "\(.applicationName) bills",
        ], shortTitle: "Upcoming Bills", systemImageName: "calendar")
        AppShortcut(intent: FinancialAlertsIntent(), phrases: [
            "Show my \(.applicationName) alerts",
        ], shortTitle: "Alerts", systemImageName: "bell.badge")
    }
}
