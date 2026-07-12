//
//  CapitalGainsReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A realised gain line for the capital-gains report, tagged with its security.
public struct CapitalGainLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var accountName: String
    public var disposalDate: Date
    public var acquisitionDate: Date?
    public var quantity: Decimal
    public var proceeds: Decimal
    public var costBasis: Decimal
    public var gain: Decimal
    public var longTerm: Bool?
}

/// An open (unsold) parcel for the lots report.
public struct OpenLotLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var accountName: String
    public var acquisitionDate: Date?
    public var quantity: Decimal
    public var costBasis: Decimal
}

/// Realised capital gains over a period plus the currently-open lots
/// (`FR-RPT-03`). Amounts are in the report currency; multi-currency FX is a
/// higher layer, so figures use each security's own transaction amounts.
public struct CapitalGainsReport: Sendable {
    public var currencyCode: String
    public var method: CostBasisMethod
    public var from: Date
    public var to: Date
    public var lines: [CapitalGainLine]
    public var openLots: [OpenLotLine]

    public var shortTermGain: Decimal {
        lines.filter { $0.longTerm == false }.reduce(0) { $0 + $1.gain }
    }
    public var longTermGain: Decimal {
        lines.filter { $0.longTerm == true }.reduce(0) { $0 + $1.gain }
    }
    /// Gains with an undefined holding period (average cost / uncovered sales).
    public var otherGain: Decimal {
        lines.filter { $0.longTerm == nil }.reduce(0) { $0 + $1.gain }
    }
    public var totalGain: Decimal { lines.reduce(0) { $0 + $1.gain } }
    public var totalProceeds: Decimal { lines.reduce(0) { $0 + $1.proceeds } }
    public var totalCostBasis: Decimal { lines.reduce(0) { $0 + $1.costBasis } }
    public var openCostBasis: Decimal { openLots.reduce(0) { $0 + $1.costBasis } }
}

public extension FinancialReports {

    /// Realised gains disposed within `[from, to]` and all open lots, computed
    /// per security account under `method` (`FR-RPT-03`).
    static func capitalGains(
        _ book: Book,
        currency: Commodity,
        from: Date = .distantPast,
        to: Date = .distantFuture,
        method: CostBasisMethod = .fifo,
        longTermThresholdDays: Int = CostBasis.defaultLongTermThresholdDays
    ) -> CapitalGainsReport {
        var lines: [CapitalGainLine] = []
        var openLots: [OpenLotLine] = []

        for account in book.accounts where account.type.isSecurityType && !account.isPlaceholder {
            let result = book.costBasis(for: account, method: method,
                                        longTermThresholdDays: longTermThresholdDays)
            let symbol = account.commodity.mnemonic

            for gain in result.realizedGains where gain.disposalDate >= from && gain.disposalDate <= to {
                lines.append(CapitalGainLine(
                    id: .random(), symbol: symbol, accountName: account.name,
                    disposalDate: gain.disposalDate, acquisitionDate: gain.acquisitionDate,
                    quantity: gain.quantity,
                    proceeds: currency.round(gain.proceeds),
                    costBasis: currency.round(gain.costBasis),
                    gain: currency.round(gain.gain),
                    longTerm: gain.longTerm))
            }

            for lot in result.openLots {
                openLots.append(OpenLotLine(
                    id: .random(), symbol: symbol, accountName: account.name,
                    acquisitionDate: lot.acquisitionDate, quantity: lot.quantity,
                    costBasis: currency.round(lot.costBasis)))
            }
        }

        return CapitalGainsReport(
            currencyCode: currency.mnemonic, method: method, from: from, to: to,
            lines: lines.sorted { $0.disposalDate < $1.disposalDate },
            openLots: openLots.sorted { ($0.acquisitionDate ?? .distantPast) < ($1.acquisitionDate ?? .distantPast) })
    }
}
