//
//  PortfolioReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One security holding in the portfolio report.
public struct PortfolioHolding: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var accountName: String
    public var symbol: String
    public var shares: Decimal
    /// Latest unit price in the report currency, if available.
    public var price: Decimal?
    /// Market value = shares × price, if a price is available.
    public var marketValue: Decimal?
    /// Cost basis (net amount paid), in the report currency.
    public var costBasis: Decimal
    /// Market value − cost basis, if valued.
    public var gain: Decimal?
    /// Gain as a fraction of cost, if valued and cost ≠ 0.
    public var gainFraction: Double?
}

/// A portfolio valuation over the security accounts (`FR-RPT-02`).
public struct Portfolio: Sendable {
    public var asOf: Date
    public var currencyCode: String
    public var holdings: [PortfolioHolding]
    public var totalCost: Decimal
    public var totalValue: Decimal
    public var totalGain: Decimal
}

public extension FinancialReports {

    /// Values every security account (stock / mutual fund) using the latest
    /// price on or before `asOf` (`FR-RPT-02`).
    static func portfolio(_ book: Book, currency: Commodity, asOf: Date = Date()) -> Portfolio {
        var holdings: [PortfolioHolding] = []
        var totalCost = Decimal(0)
        var totalValue = Decimal(0)

        for account in book.accounts where account.type.isSecurityType && !account.isPlaceholder {
            var shares = Decimal(0)
            var cost = Decimal(0)
            for transaction in book.transactions {
                for split in transaction.splits
                where split.account === account && split.reconcileState != .voided {
                    shares += split.quantity
                    cost += split.value
                }
            }
            guard shares != 0 || cost != 0 else { continue }

            let price = book.latestPrice(of: account.commodity, in: currency, on: asOf)?.value
            let marketValue = price.map { currency.round(shares * $0) }
            let roundedCost = currency.round(cost)
            let gain = marketValue.map { $0 - roundedCost }
            let gainFraction: Double? = (gain != nil && roundedCost != 0)
                ? NSDecimalNumber(decimal: gain!).doubleValue / NSDecimalNumber(decimal: roundedCost).doubleValue
                : nil

            holdings.append(PortfolioHolding(
                id: account.guid, accountName: account.name, symbol: account.commodity.mnemonic,
                shares: shares, price: price, marketValue: marketValue,
                costBasis: roundedCost, gain: gain, gainFraction: gainFraction))

            totalCost += roundedCost
            if let marketValue { totalValue += marketValue }
        }

        return Portfolio(
            asOf: asOf,
            currencyCode: currency.mnemonic,
            holdings: holdings.sorted { $0.accountName < $1.accountName },
            totalCost: currency.round(totalCost),
            totalValue: currency.round(totalValue),
            totalGain: currency.round(totalValue - totalCost))
    }
}
