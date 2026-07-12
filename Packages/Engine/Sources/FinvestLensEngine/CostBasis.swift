//
//  CostBasis.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// How disposals are matched against acquisitions to compute cost basis and
/// realised gains (`FR-INV-04`).
public enum CostBasisMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    /// First in, first out — oldest lots are sold first.
    case fifo
    /// Last in, first out — newest lots are sold first.
    case lifo
    /// Average cost — a single pooled cost per share.
    case average

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fifo: return "FIFO"
        case .lifo: return "LIFO"
        case .average: return "Average cost"
        }
    }
}

/// One acquisition-or-disposal event feeding the cost-basis calculator.
///
/// `quantity` is a number of shares — positive for an acquisition, negative for
/// a disposal. `value` is the signed cash amount in the transaction currency:
/// positive cost for a buy, negative proceeds for a sell (matching the security
/// split's sign convention).
///
/// When ``isSplit`` is set the event is a stock split: `quantity` is the number
/// of shares *added* by the split (negative for a reverse split) and `value` is
/// ignored. A split rescales the open lots — multiplying share counts and
/// dividing per-share cost — so total cost basis is preserved.
public struct LotEvent: Hashable, Sendable {
    public var date: Date
    public var quantity: Decimal
    public var value: Decimal
    public var isSplit: Bool
    /// A return-of-capital distribution: `value` (negative) reduces the cost
    /// basis of the open lots pro rata without moving shares.
    public var isReturnOfCapital: Bool

    public init(date: Date, quantity: Decimal, value: Decimal,
                isSplit: Bool = false, isReturnOfCapital: Bool = false) {
        self.date = date
        self.quantity = quantity
        self.value = value
        self.isSplit = isSplit
        self.isReturnOfCapital = isReturnOfCapital
    }
}

/// A still-open parcel of shares with its remaining cost basis.
public struct OpenLot: Hashable, Sendable {
    /// Acquisition date, or `nil` for a pooled (average-cost) lot.
    public let acquisitionDate: Date?
    public let quantity: Decimal
    public let costBasis: Decimal

    public init(acquisitionDate: Date?, quantity: Decimal, costBasis: Decimal) {
        self.acquisitionDate = acquisitionDate
        self.quantity = quantity
        self.costBasis = costBasis
    }

    /// Cost of one remaining share (0 when the lot is empty).
    public var costPerShare: Decimal {
        quantity != 0 ? costBasis / quantity : 0
    }
}

/// A realised gain (or loss) from disposing of shares against one lot.
public struct RealizedGain: Hashable, Sendable {
    public let disposalDate: Date
    /// The matched acquisition date, or `nil` for average-cost / uncovered sales.
    public let acquisitionDate: Date?
    public let quantity: Decimal
    public let proceeds: Decimal
    public let costBasis: Decimal
    /// `true` if held at least the long-term threshold, `false` if shorter,
    /// `nil` when undefined (average cost, or an uncovered short sale).
    public let longTerm: Bool?

    public init(disposalDate: Date, acquisitionDate: Date?, quantity: Decimal,
                proceeds: Decimal, costBasis: Decimal, longTerm: Bool?) {
        self.disposalDate = disposalDate
        self.acquisitionDate = acquisitionDate
        self.quantity = quantity
        self.proceeds = proceeds
        self.costBasis = costBasis
        self.longTerm = longTerm
    }

    /// Proceeds minus cost basis.
    public var gain: Decimal { proceeds - costBasis }

    /// Whole days the shares were held, when an acquisition date is known.
    public var holdingDays: Int? {
        guard let acquisitionDate else { return nil }
        return Int(disposalDate.timeIntervalSince(acquisitionDate) / 86_400)
    }
}

/// The outcome of running the cost-basis calculator over a security's events.
public struct CostBasisResult: Sendable {
    public let method: CostBasisMethod
    public let openLots: [OpenLot]
    public let realizedGains: [RealizedGain]

    public var remainingQuantity: Decimal { openLots.reduce(0) { $0 + $1.quantity } }
    public var remainingCostBasis: Decimal { openLots.reduce(0) { $0 + $1.costBasis } }
    public var totalProceeds: Decimal { realizedGains.reduce(0) { $0 + $1.proceeds } }
    public var totalCostBasis: Decimal { realizedGains.reduce(0) { $0 + $1.costBasis } }
    public var totalRealizedGain: Decimal { realizedGains.reduce(0) { $0 + $1.gain } }
}

/// Computes cost basis and realised gains from a stream of ``LotEvent``s.
public enum CostBasis {

    /// The conventional short/long-term boundary (one year).
    public static let defaultLongTermThresholdDays = 365

    /// Matches disposals against acquisitions by `method`, producing open lots
    /// and a realised-gain record per matched parcel.
    ///
    /// Proceeds are allocated to matched parcels pro rata by share count, so a
    /// sale spanning several lots splits into one ``RealizedGain`` per lot with
    /// its own holding period.
    public static func compute(
        events: [LotEvent],
        method: CostBasisMethod,
        longTermThresholdDays: Int = defaultLongTermThresholdDays
    ) -> CostBasisResult {
        // Stable chronological order; acquisitions before disposals on a tie by
        // preserving original index.
        let ordered = events.enumerated().sorted { lhs, rhs in
            if lhs.element.date != rhs.element.date { return lhs.element.date < rhs.element.date }
            return lhs.offset < rhs.offset
        }.map(\.element)

        switch method {
        case .fifo, .lifo:
            return matchedLots(ordered, lifo: method == .lifo,
                               method: method, threshold: longTermThresholdDays)
        case .average:
            return averageCost(ordered)
        }
    }

    // MARK: FIFO / LIFO

    private struct MutableLot {
        let date: Date
        var remaining: Decimal
        var costPerShare: Decimal
    }

    private static func matchedLots(
        _ events: [LotEvent], lifo: Bool, method: CostBasisMethod, threshold: Int
    ) -> CostBasisResult {
        var open: [MutableLot] = []
        var gains: [RealizedGain] = []

        for event in events {
            if event.isSplit {
                // Rescale every open lot so total cost is preserved: shares grow
                // by the split ratio, per-share cost shrinks by it.
                let current = open.reduce(Decimal(0)) { $0 + $1.remaining }
                if current > 0 {
                    let ratio = (current + event.quantity) / current
                    if ratio > 0 {
                        for index in open.indices {
                            open[index].remaining *= ratio
                            open[index].costPerShare /= ratio
                        }
                    }
                }
                continue
            }
            if event.isReturnOfCapital {
                // Reduce basis pro rata by remaining cost; floor at zero.
                let totalCost = open.reduce(Decimal(0)) { $0 + $1.remaining * $1.costPerShare }
                let reduction = min(-event.value, totalCost)
                if totalCost > 0, reduction > 0 {
                    for index in open.indices where open[index].remaining != 0 {
                        let lotCost = open[index].remaining * open[index].costPerShare
                        let newLotCost = max(0, lotCost - reduction * (lotCost / totalCost))
                        open[index].costPerShare = newLotCost / open[index].remaining
                    }
                }
                continue
            }
            if event.quantity > 0 {
                let perShare = event.value / event.quantity
                open.append(MutableLot(date: event.date, remaining: event.quantity, costPerShare: perShare))
            } else if event.quantity < 0 {
                var sharesToSell = -event.quantity
                let proceedsPerShare = sharesToSell != 0 ? (-event.value) / sharesToSell : 0

                while sharesToSell > 0, !open.isEmpty {
                    let index = lifo ? open.count - 1 : 0
                    let take = min(open[index].remaining, sharesToSell)
                    let costBasis = take * open[index].costPerShare
                    let proceeds = take * proceedsPerShare
                    let heldDays = Int(event.date.timeIntervalSince(open[index].date) / 86_400)
                    gains.append(RealizedGain(
                        disposalDate: event.date, acquisitionDate: open[index].date,
                        quantity: take, proceeds: proceeds, costBasis: costBasis,
                        longTerm: heldDays >= threshold))
                    open[index].remaining -= take
                    sharesToSell -= take
                    if open[index].remaining == 0 { open.remove(at: index) }
                }

                // Uncovered sale (sold more than held): zero cost basis, unknown
                // holding period.
                if sharesToSell > 0 {
                    gains.append(RealizedGain(
                        disposalDate: event.date, acquisitionDate: nil,
                        quantity: sharesToSell, proceeds: sharesToSell * proceedsPerShare,
                        costBasis: 0, longTerm: nil))
                }
            }
        }

        let openLots = open.map {
            OpenLot(acquisitionDate: $0.date, quantity: $0.remaining,
                    costBasis: $0.remaining * $0.costPerShare)
        }
        return CostBasisResult(method: method, openLots: openLots, realizedGains: gains)
    }

    // MARK: Average cost

    private static func averageCost(_ events: [LotEvent]) -> CostBasisResult {
        var pooledShares = Decimal(0)
        var pooledCost = Decimal(0)
        var gains: [RealizedGain] = []

        for event in events {
            if event.isSplit {
                // Cost pool is unchanged; only the share count moves.
                pooledShares += event.quantity
                continue
            }
            if event.isReturnOfCapital {
                pooledCost = max(0, pooledCost + event.value)   // value is negative
                continue
            }
            if event.quantity > 0 {
                pooledShares += event.quantity
                pooledCost += event.value
            } else if event.quantity < 0 {
                let sharesSold = -event.quantity
                let proceeds = -event.value
                let avg = pooledShares != 0 ? pooledCost / pooledShares : 0
                let costBasis = avg * sharesSold
                gains.append(RealizedGain(
                    disposalDate: event.date, acquisitionDate: nil,
                    quantity: sharesSold, proceeds: proceeds, costBasis: costBasis,
                    longTerm: nil))
                pooledShares -= sharesSold
                pooledCost -= costBasis
                if pooledShares <= 0 { pooledShares = 0; pooledCost = 0 }
            }
        }

        let openLots = pooledShares > 0
            ? [OpenLot(acquisitionDate: nil, quantity: pooledShares, costBasis: pooledCost)]
            : []
        return CostBasisResult(method: .average, openLots: openLots, realizedGains: gains)
    }
}
