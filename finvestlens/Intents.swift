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

// MARK: - Account entity (App Entity + Spotlight)

/// A book account exposed to Shortcuts, Siri and Spotlight (`IndexedEntity`),
/// so "CBA balance" or an account's name resolves in system search.
struct AccountEntity: AppEntity, IndexedEntity {
    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Balance") var balance: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Account")
    static let defaultQuery = AccountEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(balance)")
    }

    init(id: String, name: String, balance: String) {
        self.id = id
        self.name = name
        self.balance = balance
    }

    init(_ info: IntentSupport.AccountInfo) {
        self.init(id: info.id, name: info.name, balance: info.balance)
    }
}

/// Resolves ``AccountEntity`` values by id, as suggestions, and by free-text
/// (the last conformance is what lets Spotlight match on a typed name).
struct AccountEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        let wanted = Set(identifiers)
        return IntentSupport.accounts().filter { wanted.contains($0.id) }.map(AccountEntity.init)
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        IntentSupport.accounts().map(AccountEntity.init)
    }

    func entities(matching string: String) async throws -> [AccountEntity] {
        IntentSupport.accounts()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(AccountEntity.init)
    }
}

/// Reports a chosen account's balance (`FR-PLT-03`).
struct AccountBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Account Balance"
    static let description = IntentDescription("Reports the balance of an account in your FinvestLens book.")

    @Parameter(title: "Account") var account: AccountEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show the balance of \(\.$account)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let balance = IntentSupport.accountBalance(id: account.id) ?? "unavailable"
        return .result(dialog: IntentDialog(stringLiteral: "\(account.name) balance is \(balance)."))
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
        AppShortcut(intent: AccountBalanceIntent(), phrases: [
            "Show an account balance in \(.applicationName)",
            "\(.applicationName) account balance",
        ], shortTitle: "Account Balance", systemImageName: "banknote")
    }
}
