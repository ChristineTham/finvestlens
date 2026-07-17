//
//  InvestmentLotsReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One open tax lot with its current valuation (`FR-RPT-02`, Investment Lots).
public struct LotDetail: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var accountName: String
    public var acquisitionDate: Date?
    public var quantity: Decimal
    public var costBasis: Decimal
    /// Unit price in the report currency, if available.
    public var price: Decimal?
    public var marketValue: Decimal?
    public var unrealizedGain: Decimal?
    /// Whole days held to `asOf`, when an acquisition date is known.
    public var holdingDays: Int?
}

public extension FinancialReports {

    /// Every open lot across all security accounts, valued at the price on or
    /// before `asOf` (`FR-RPT-02`, Investment Lots report).
    static func investmentLots(
        _ book: Book,
        currency: Commodity,
        asOf: Date = Date(),
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore
    ) -> [LotDetail] {
        var details: [LotDetail] = []

        for account in book.accounts where account.type.isSecurityType && !account.isPlaceholder {
            let result = book.costBasis(for: account, method: method, feeTreatment: feeTreatment)
            let symbol = account.commodity.mnemonic
            let price = book.securityUnitValue(account.commodity, in: currency, on: asOf)

            for lot in result.openLots {
                let cost = currency.round(lot.costBasis)
                let marketValue = price.map { currency.round(lot.quantity * $0) }
                let unrealized = marketValue.map { $0 - cost }
                let days = lot.acquisitionDate.map { Int(asOf.timeIntervalSince($0) / 86_400) }
                details.append(LotDetail(
                    id: .random(), symbol: symbol, accountName: account.name,
                    acquisitionDate: lot.acquisitionDate, quantity: lot.quantity,
                    costBasis: cost, price: price, marketValue: marketValue,
                    unrealizedGain: unrealized, holdingDays: days))
            }
        }

        return details.sorted {
            ($0.acquisitionDate ?? .distantPast) < ($1.acquisitionDate ?? .distantPast)
        }
    }
}
