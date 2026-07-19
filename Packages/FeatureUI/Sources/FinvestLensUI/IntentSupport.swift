//
//  IntentSupport.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensPersistence
import FinvestLensReports
import FinvestLensShared
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Read-only summaries for App Intents / Shortcuts / widgets, driven by the
/// last-opened book (`FR-PLT-03`). Loading uses the store directly (no lock /
/// working copy) since these are read-only.
public enum IntentSupport {

    static func lastBook() -> Book? {
        guard let path = UserDefaults.standard.string(forKey: "finvestlens.lastBookPath"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return try? SQLiteDocumentStore(path: path).read()
    }

    static func baseCurrency(_ book: Book) -> Commodity {
        book.commodities.first { $0.namespace == .currency } ?? .aud
    }

    private static func decodeScheduled(_ book: Book) -> [ScheduledTransaction] {
        guard case let .string(json)? = book.kvp["finvestlens/scheduledTransactions"],
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ScheduledTransaction].self, from: data)) ?? []
    }

    private static func money(_ value: Decimal, _ currency: Commodity) -> String {
        AmountFormat.string(value, code: currency.mnemonic)
    }

    /// "Your net worth is $X."
    public static func netWorthSummary() -> String {
        guard let book = lastBook() else { return "No FinvestLens book has been opened yet." }
        let currency = baseCurrency(book)
        let value = FinancialReports.netWorthSeries(book, dates: [Date()], currency: currency).last?.netWorth ?? 0
        return "Your net worth is \(money(value, currency))."
    }

    /// "You have N upcoming bills totalling $X."
    public static func upcomingBillsSummary() -> String {
        guard let book = lastBook() else { return "No FinvestLens book has been opened yet." }
        let currency = baseCurrency(book)
        let now = Date()
        let bills = FinancialReports.billReminders(
            book, scheduled: decodeScheduled(book),
            from: now.addingTimeInterval(-30 * 86_400),
            to: now.addingTimeInterval(60 * 86_400), asOf: now
        ).filter { $0.status != .paid }
        guard !bills.isEmpty else { return "You have no upcoming bills." }
        let total = bills.reduce(Decimal(0)) { $0 + $1.amount }
        return "You have \(bills.count) upcoming bill\(bills.count == 1 ? "" : "s") totalling \(money(total, currency))."
    }

    // MARK: - Accounts (App Entity / Spotlight)

    /// A postable account exposed to App Intents / Spotlight.
    public struct AccountInfo: Sendable, Identifiable {
        public let id: String       // account GUID hex
        public let name: String     // full colon-path name
        public let balance: String  // formatted in the account's own commodity
    }

    /// Every non-placeholder account, for `AppEntity` suggestions and Spotlight
    /// indexing. Balances are in each account's own commodity.
    public static func accounts() -> [AccountInfo] {
        guard let book = lastBook() else { return [] }
        return book.accounts
            .filter { !$0.isPlaceholder }
            .map { account in
                let amount = book.balance(of: account).amount
                return AccountInfo(id: account.guid.hexString, name: account.fullName,
                                   balance: Money(amount, account.commodity).formatted())
            }
    }

    /// A single account's formatted balance, by GUID hex — for a parameterized
    /// "account balance" intent.
    public static func accountBalance(id: String) -> String? {
        guard let book = lastBook(),
              let account = book.accounts.first(where: { $0.guid.hexString == id })
        else { return nil }
        return Money(book.balance(of: account).amount, account.commodity).formatted()
    }

    /// The current alerts as a spoken/short summary.
    public static func alertsSummary() -> String {
        guard let book = lastBook() else { return "No FinvestLens book has been opened yet." }
        let currency = baseCurrency(book)
        let alerts = FinancialReports.alerts(book, scheduled: decodeScheduled(book),
                                             currency: currency)
        guard !alerts.isEmpty else { return "Nothing needs your attention." }
        let top = alerts.prefix(3).map(\.title).joined(separator: "; ")
        return alerts.count <= 3 ? top : "\(top); and \(alerts.count - 3) more."
    }

    // MARK: - Widget / Quick Look snapshot (FR-PLT-03)

    /// Builds the small snapshot the app publishes to the App Group container
    /// for its WidgetKit and Quick Look extensions. Returns a neutral
    /// placeholder when no book has been opened.
    public static func snapshot() -> WidgetSnapshot {
        guard let book = lastBook() else { return .placeholder }
        let currency = baseCurrency(book)
        let scheduled = decodeScheduled(book)
        let now = Date()

        let netWorth = FinancialReports.netWorthSeries(book, dates: [now], currency: currency)
            .last?.netWorth ?? 0

        let bills = FinancialReports.billReminders(
            book, scheduled: scheduled,
            from: now.addingTimeInterval(-30 * 86_400),
            to: now.addingTimeInterval(60 * 86_400), asOf: now
        ).filter { $0.status != .paid }
        let billsLine: String
        if bills.isEmpty {
            billsLine = "No upcoming bills"
        } else {
            let total = bills.reduce(Decimal(0)) { $0 + $1.amount }
            billsLine = "\(bills.count) bill\(bills.count == 1 ? "" : "s") due · \(money(total, currency))"
        }

        let alerts = FinancialReports.alerts(book, scheduled: scheduled, currency: currency)
            .prefix(5)
            .map { WidgetSnapshot.Alert(title: $0.title, message: $0.message, severity: $0.severity.rawValue) }

        let name = UserDefaults.standard.string(forKey: "finvestlens.lastBookPath")
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "FinvestLens"

        return WidgetSnapshot(
            bookName: name,
            netWorth: money(netWorth, currency),
            upcomingBills: billsLine,
            alerts: Array(alerts),
            updatedAt: now
        )
    }

    /// Recomputes and writes the snapshot, then asks WidgetKit to reload. Safe to
    /// call after every refresh/save; a no-op for the file write when the App
    /// Group is not yet provisioned.
    public static func publishWidgetSnapshot() {
        snapshot().write()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
