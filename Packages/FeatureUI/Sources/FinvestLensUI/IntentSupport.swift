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
}
