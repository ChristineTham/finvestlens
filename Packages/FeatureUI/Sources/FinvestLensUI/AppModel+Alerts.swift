//
//  AppModel+Alerts.swift
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

    /// Proactive alerts across bills, budgets, cash-flow forecast and price
    /// targets, most-severe first (`FR-PLAN-05`).
    public func alerts(asOf: Date = Date()) -> [FinancialAlert] {
        guard let book else { return [] }
        return FinancialReports.alerts(
            book, scheduled: scheduledTransactions, budgets: budgets,
            currency: reportCurrency, asOf: asOf,
            forecastAccountID: defaultForecastAccountID,
            priceTargets: priceTargets)
    }

    // MARK: Price targets

    /// Sets (or replaces) a price target for a security.
    public func setPriceTarget(_ commodity: Commodity, target: Decimal, direction: PriceTarget.Direction) {
        priceTargets.removeAll { $0.commodity == commodity }
        priceTargets.append(PriceTarget(commodity: commodity, target: target, direction: direction))
        commitKvpCollections(named: "Set Price Target")
    }

    public func removePriceTarget(_ commodity: Commodity) {
        priceTargets.removeAll { $0.commodity == commodity }
        commitKvpCollections(named: "Remove Price Target")
    }

    /// The existing target for a security, if any.
    public func priceTarget(for commodity: Commodity) -> PriceTarget? {
        priceTargets.first { $0.commodity == commodity }
    }
}
