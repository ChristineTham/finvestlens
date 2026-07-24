//
//  AppModel+Forecast.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

@MainActor
extension AppModel {

    /// A sensible default account to forecast (the first asset-like account).
    public var defaultForecastAccountID: GncGUID? {
        book?.accounts.first { $0.type.isAssetLike && !$0.isPlaceholder }?.guid
    }

    /// Projects an account's balance forward `months` months from `from` using
    /// the document's scheduled transactions and any what-if events
    /// (`FR-PLAN-02`, `FR-PLAN-03`).
    public func cashFlowForecast(accountID: GncGUID, months: Int = 6,
                                 from: Date = Date()) -> [CashFlowPoint] {
        guard let book else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        // Quantised for the memo key; what-if events are session state, so
        // they join the key rather than invalidating the whole cache.
        let start = min(from, Self.endOfToday())
        let horizon = calendar.date(byAdding: .month, value: months, to: start) ?? start
        return cachedReport("fcast:\(accountID.hexString):\(months):\(start.timeIntervalSinceReferenceDate):\(whatIfEvents.hashValue)") {
            FinancialReports.cashFlowForecast(book, accountID: accountID,
                                              scheduled: scheduledTransactions,
                                              from: start, horizon: horizon, currency: reportCurrency,
                                              whatIf: whatIfEvents)
        } ?? []
    }

    /// Upcoming/overdue bills from scheduled transactions over a window around
    /// `asOf` (30 days back … 60 days ahead) (`FR-BILL-01`).
    public func billReminders(asOf: Date = Date()) -> [BillReminder] {
        guard let book else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let from = calendar.date(byAdding: .day, value: -30, to: asOf) ?? asOf
        let to = calendar.date(byAdding: .day, value: 60, to: asOf) ?? asOf
        return FinancialReports.billReminders(book, scheduled: scheduledTransactions,
                                              from: from, to: to, asOf: asOf)
    }

    /// Adds a hypothetical what-if event to the cash-flow forecast (session-only,
    /// not persisted).
    public func addWhatIfEvent(date: Date, amount: Decimal, label: String) {
        whatIfEvents.append(WhatIfEvent(date: date, amount: amount,
                                        label: label.isEmpty ? "What-if" : label))
    }

    public func removeWhatIfEvent(_ id: UUID) {
        whatIfEvents.removeAll { $0.id == id }
    }
}
