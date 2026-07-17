//
//  AdvancedPortfolioReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A holding in the advanced portfolio, tying market value to the lot engine so
/// cost basis reflects only the shares still held (`FR-RPT-02a`).
public struct AdvancedHolding: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var accountName: String
    public var symbol: String
    /// Shares still held (from the lot engine).
    public var shares: Decimal
    /// Cost basis of the shares still held.
    public var costBasis: Decimal
    /// Average cost per held share, if any shares remain.
    public var averageCost: Decimal?
    /// Latest unit price in the report currency, if available.
    public var price: Decimal?
    /// shares × price, if priced.
    public var marketValue: Decimal?
    /// Market value − cost basis, if priced.
    public var unrealizedGain: Decimal?
    /// Unrealized gain as a fraction of cost, if priced and cost ≠ 0.
    public var unrealizedFraction: Double?
    /// Realized gain to date from disposals (from the lot engine).
    public var realizedGain: Decimal
    /// Share of the total portfolio market value, if priced.
    public var allocation: Double?
}

/// A richer portfolio valuation: per-holding cost basis, average cost,
/// unrealized/realized gains, and asset allocation (`FR-RPT-02a`).
public struct AdvancedPortfolio: Sendable {
    public var asOf: Date
    public var currencyCode: String
    public var method: CostBasisMethod
    public var holdings: [AdvancedHolding]
    public var totalCost: Decimal
    public var totalValue: Decimal
    public var totalUnrealized: Decimal
    public var totalRealized: Decimal

    /// Simple total return: (unrealized + realized) ÷ cost basis of holdings
    /// (`nil` when there is no cost basis).
    public var totalReturnFraction: Double? {
        guard totalCost != 0 else { return nil }
        let gain = totalUnrealized + totalRealized
        return NSDecimalNumber(decimal: gain).doubleValue / NSDecimalNumber(decimal: totalCost).doubleValue
    }
}

public extension FinancialReports {

    /// Values every security account using the lot engine for cost basis and the
    /// price DB (with an FX hop for foreign securities) for market value.
    static func advancedPortfolio(
        _ book: Book,
        currency: Commodity,
        asOf: Date = Date(),
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore
    ) -> AdvancedPortfolio {
        struct Raw {
            let account: Account
            let shares: Decimal
            let costBasis: Decimal
            let realized: Decimal
            let price: Decimal?
            let marketValue: Decimal?
        }

        var raws: [Raw] = []
        var totalValue = Decimal(0)

        for account in book.accounts where account.type.isSecurityType && !account.isPlaceholder {
            let basis = book.costBasis(for: account, method: method, feeTreatment: feeTreatment,
                                       currencyFraction: currency.smallestFraction)
            let shares = basis.remainingQuantity
            guard shares != 0 || basis.totalRealizedGain != 0 else { continue }

            let cost = currency.round(basis.remainingCostBasis)
            let price = book.securityUnitValue(account.commodity, in: currency, on: asOf)
            let marketValue = price.map { currency.round(shares * $0) }
            if let marketValue { totalValue += marketValue }

            raws.append(Raw(account: account, shares: shares, costBasis: cost,
                            realized: currency.round(basis.totalRealizedGain),
                            price: price, marketValue: marketValue))
        }

        var holdings: [AdvancedHolding] = []
        var totalCost = Decimal(0)
        var totalUnrealized = Decimal(0)
        var totalRealized = Decimal(0)

        for raw in raws {
            let unrealized = raw.marketValue.map { $0 - raw.costBasis }
            let unrealizedFraction: Double? = (unrealized != nil && raw.costBasis != 0)
                ? NSDecimalNumber(decimal: unrealized!).doubleValue / NSDecimalNumber(decimal: raw.costBasis).doubleValue
                : nil
            let averageCost = raw.shares != 0 ? raw.costBasis / raw.shares : nil
            let allocation: Double? = (raw.marketValue != nil && totalValue != 0)
                ? NSDecimalNumber(decimal: raw.marketValue!).doubleValue / NSDecimalNumber(decimal: totalValue).doubleValue
                : nil

            holdings.append(AdvancedHolding(
                id: raw.account.guid, accountName: raw.account.name,
                symbol: raw.account.commodity.mnemonic, shares: raw.shares,
                costBasis: raw.costBasis, averageCost: averageCost,
                price: raw.price, marketValue: raw.marketValue,
                unrealizedGain: unrealized, unrealizedFraction: unrealizedFraction,
                realizedGain: raw.realized, allocation: allocation))

            totalCost += raw.costBasis
            if let unrealized { totalUnrealized += unrealized }
            totalRealized += raw.realized
        }

        return AdvancedPortfolio(
            asOf: asOf, currencyCode: currency.mnemonic, method: method,
            holdings: holdings.sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) },
            totalCost: currency.round(totalCost),
            totalValue: currency.round(totalValue),
            totalUnrealized: currency.round(totalUnrealized),
            totalRealized: currency.round(totalRealized))
    }
}
