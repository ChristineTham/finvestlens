//
//  AppModel+Prices.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

/// A row in the price editor.
public struct PriceRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var currencyCode: String
    public var date: Date
    public var value: Decimal
}

@MainActor
extension AppModel {

    /// Commodities that are held in a security account (candidates to price).
    public var securityCommodities: [Commodity] {
        guard let book else { return [] }
        var seen = Set<String>()
        var result: [Commodity] = []
        for account in book.accounts where account.type.isSecurityType {
            let key = "\(account.commodity.namespace)|\(account.commodity.mnemonic)"
            if seen.insert(key).inserted { result.append(account.commodity) }
        }
        return result
    }

    /// Adds a price to the database (`FR-INV-02`).
    public func addPrice(commodity: Commodity, currency: Commodity, date: Date, value: Decimal) {
        guard let book else { return }
        book.addPrice(Price(commodity: commodity, currency: currency, date: date, value: value))
        markDirtyAndRefresh()
    }

    public func deletePrice(_ id: GncGUID) {
        guard let book else { return }
        book.removePrice(id)
        markDirtyAndRefresh()
    }

    /// The portfolio valuation over security accounts (`FR-RPT-02`).
    public func portfolio(asOf: Date = Date()) -> Portfolio? {
        guard let book, !securityCommodities.isEmpty else { return nil }
        return FinancialReports.portfolio(book, currency: reportCurrency, asOf: asOf)
    }

    /// Realised capital gains and open lots under the selected cost-basis
    /// method (`FR-RPT-03`).
    public func capitalGains(from: Date = .distantPast, to: Date = .distantFuture) -> CapitalGainsReport? {
        guard let book, !securityCommodities.isEmpty else { return nil }
        return FinancialReports.capitalGains(book, currency: reportCurrency,
                                             from: from, to: to, method: costBasisMethod)
    }

    /// The advanced portfolio (cost basis, avg cost, unrealized/realized gain,
    /// allocation) under the selected cost-basis method (`FR-RPT-02a`).
    public func advancedPortfolio(asOf: Date = Date()) -> AdvancedPortfolio? {
        guard let book, !securityCommodities.isEmpty else { return nil }
        return FinancialReports.advancedPortfolio(book, currency: reportCurrency,
                                                  asOf: asOf, method: costBasisMethod)
    }

    /// Securities that have at least one recorded price (candidates for the
    /// price-history chart).
    public var securitiesWithPriceHistory: [Commodity] {
        guard let book else { return [] }
        var seen = Set<String>()
        var result: [Commodity] = []
        for price in book.prices where price.commodity.namespace != .currency {
            if seen.insert(price.commodity.mnemonic).inserted { result.append(price.commodity) }
        }
        return result.sorted { $0.mnemonic < $1.mnemonic }
    }

    /// The recorded price series for `commodity`, oldest first.
    public func priceHistory(for commodity: Commodity) -> [PricePoint] {
        guard let book else { return [] }
        return book.prices
            .filter { $0.commodity == commodity }
            .sorted { $0.date < $1.date }
            .map { PricePoint(date: $0.date, value: $0.value, currencyCode: $0.currency.mnemonic) }
    }
}

/// One point in a security's price-history chart.
public struct PricePoint: Identifiable, Hashable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var value: Decimal
    public var currencyCode: String
}
