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
        let horizon = calendar.date(byAdding: .month, value: months, to: from) ?? from
        return FinancialReports.cashFlowForecast(book, accountID: accountID,
                                                 scheduled: scheduledTransactions,
                                                 from: from, horizon: horizon, currency: reportCurrency,
                                                 whatIf: whatIfEvents)
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
