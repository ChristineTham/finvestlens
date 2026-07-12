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
}
