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

/// How brokerage/commission fees on a security transaction affect cost basis
/// and realised gains — mirrors GnuCash's Advanced Portfolio option.
public enum FeeTreatment: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Fees are folded into cost basis: a buy's fee raises the lot's cost, a
    /// sale's fee raises the realised cost basis of that disposal. This is
    /// GnuCash's default.
    case includeInBasis
    /// Fees are excluded from cost basis and realised gains entirely.
    case ignore

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .includeInBasis: return "Include in basis"
        case .ignore: return "Ignore fees"
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
    /// Brokerage/commission on the event's transaction (a positive amount),
    /// applied only under ``FeeTreatment/includeInBasis``.
    public var fee: Decimal

    public init(date: Date, quantity: Decimal, value: Decimal,
                isSplit: Bool = false, isReturnOfCapital: Bool = false,
                fee: Decimal = 0) {
        self.date = date
        self.quantity = quantity
        self.value = value
        self.isSplit = isSplit
        self.isReturnOfCapital = isReturnOfCapital
        self.fee = fee
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
///
/// A buy that covers an earlier uncovered sale also produces a record: zero
/// proceeds, the buy-back cost as basis (a negative gain), dated at the cover.
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
    /// Shares sold uncovered and never bought back — an outstanding short
    /// position, so ``remainingQuantity`` reflects the true account balance.
    public let shortQuantity: Decimal

    public var remainingQuantity: Decimal { openLots.reduce(0) { $0 + $1.quantity } - shortQuantity }
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
    /// - Parameter currencyFraction: the value currency's smallest fraction
    ///   (e.g. 100 for cents). When given, each disposal's basis and proceeds
    ///   are rounded to it (half away from zero) *before* summing — matching
    ///   GnuCash's cap-gains, which reduces the basis to the currency SCU with
    ///   `RND_ROUND_HALF_UP`. A multi-lot sale allocates its proceeds pro rata
    ///   with the last parcel absorbing the rounding remainder, as GnuCash does
    ///   when it splits the sell across lots. `nil` keeps full precision.
    public static func compute(
        events: [LotEvent],
        method: CostBasisMethod,
        longTermThresholdDays: Int = defaultLongTermThresholdDays,
        feeTreatment: FeeTreatment = .ignore,
        currencyFraction: Int? = nil
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
                               method: method, threshold: longTermThresholdDays,
                               feeTreatment: feeTreatment, fraction: currencyFraction)
        case .average:
            return averageCost(ordered, feeTreatment: feeTreatment, fraction: currencyFraction)
        }
    }

    /// Rounds `value` to `1/fraction` (half away from zero, GnuCash's
    /// `RND_ROUND_HALF_UP`); identity when `fraction` is `nil`.
    static func rounded(_ value: Decimal, _ fraction: Int?) -> Decimal {
        guard let fraction, fraction > 0 else { return value }
        var input = value * Decimal(fraction)
        var out = Decimal()
        NSDecimalRound(&out, &input, 0, .plain)
        return out / Decimal(fraction)
    }

    // MARK: FIFO / LIFO

    private struct MutableLot {
        let date: Date
        var remaining: Decimal
        var costPerShare: Decimal
    }

    /// An open short position: shares sold that haven't been bought back. It
    /// remembers the sale's proceeds and fee so the realised gain can be struck
    /// when a later buy covers it — GnuCash opens a negative lot and computes
    /// the gain only on the closing (covering) split.
    private struct MutableShort {
        let date: Date              // the short-sale date (the opening)
        var remainingShares: Decimal
        var remainingProceeds: Decimal
        var remainingFee: Decimal
    }

    private static func matchedLots(
        _ events: [LotEvent], lifo: Bool, method: CostBasisMethod, threshold: Int,
        feeTreatment: FeeTreatment, fraction: Int?
    ) -> CostBasisResult {
        var open: [MutableLot] = []
        var shorts: [MutableShort] = []   // uncovered sales awaiting a buy-back
        var gains: [RealizedGain] = []
        let includeFees = feeTreatment == .includeInBasis

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
                // A buy's fee raises its cost basis (include-in-basis mode).
                let cost = event.value + (includeFees ? event.fee : 0)
                let perShare = cost / event.quantity
                var quantity = event.quantity
                // A buy after an uncovered sale first closes the short. GnuCash
                // strikes the realised gain here, on the covering split, dated
                // at the buy: the short-sale proceeds less the buy-back cost.
                while quantity > 0, !shorts.isEmpty {
                    let index = lifo ? shorts.count - 1 : 0
                    let cover = min(quantity, shorts[index].remainingShares)
                    let proceeds = rounded(
                        shorts[index].remainingProceeds * cover / shorts[index].remainingShares, fraction)
                    let shortFee = rounded(
                        shorts[index].remainingFee * cover / shorts[index].remainingShares, fraction)
                    let coverCost = rounded(cover * perShare, fraction) + shortFee
                    let heldDays = Int(event.date.timeIntervalSince(shorts[index].date) / 86_400)
                    gains.append(RealizedGain(
                        disposalDate: event.date, acquisitionDate: shorts[index].date,
                        quantity: cover, proceeds: proceeds, costBasis: coverCost,
                        longTerm: heldDays >= threshold))
                    shorts[index].remainingProceeds -= proceeds
                    shorts[index].remainingFee -= shortFee
                    shorts[index].remainingShares -= cover
                    quantity -= cover
                    if shorts[index].remainingShares == 0 { shorts.remove(at: index) }
                }
                if quantity > 0 {
                    open.append(MutableLot(date: event.date, remaining: quantity, costPerShare: perShare))
                }
            } else if event.quantity < 0 {
                var sharesToSell = -event.quantity
                // The sale's total proceeds and fee are cent-exact amounts from
                // the transaction; they are allocated pro rata across matched
                // lots, and the final parcel (share ratio 1) absorbs the
                // rounding remainder — mirroring GnuCash's per-lot sell split.
                var proceedsRemaining = -event.value
                var feeRemaining = includeFees ? event.fee : 0

                while sharesToSell > 0, !open.isEmpty {
                    let index = lifo ? open.count - 1 : 0
                    let take = min(open[index].remaining, sharesToSell)
                    let proceeds = rounded(proceedsRemaining * take / sharesToSell, fraction)
                    let feeThis = rounded(feeRemaining * take / sharesToSell, fraction)
                    let costBasis = rounded(take * open[index].costPerShare, fraction) + feeThis
                    let heldDays = Int(event.date.timeIntervalSince(open[index].date) / 86_400)
                    gains.append(RealizedGain(
                        disposalDate: event.date, acquisitionDate: open[index].date,
                        quantity: take, proceeds: proceeds, costBasis: costBasis,
                        longTerm: heldDays >= threshold))
                    proceedsRemaining -= proceeds
                    feeRemaining -= feeThis
                    open[index].remaining -= take
                    sharesToSell -= take
                    if open[index].remaining == 0 { open.remove(at: index) }
                }

                // Uncovered sale (sold more than held): open a short position.
                // No gain is realised yet — an open short has only unrealised
                // P&L — its proceeds are struck against the eventual buy-back.
                if sharesToSell > 0 {
                    shorts.append(MutableShort(
                        date: event.date, remainingShares: sharesToSell,
                        remainingProceeds: proceedsRemaining, remainingFee: feeRemaining))
                }
            }
        }

        let openLots = open.map {
            OpenLot(acquisitionDate: $0.date, quantity: $0.remaining,
                    costBasis: $0.remaining * $0.costPerShare)
        }
        let shortfall = shorts.reduce(Decimal(0)) { $0 + $1.remainingShares }
        return CostBasisResult(method: method, openLots: openLots,
                               realizedGains: gains, shortQuantity: shortfall)
    }

    // MARK: Average cost

    private static func averageCost(_ events: [LotEvent],
                                    feeTreatment: FeeTreatment,
                                    fraction: Int?) -> CostBasisResult {
        var pooledShares = Decimal(0)
        var pooledCost = Decimal(0)
        var shorts: [MutableShort] = []   // uncovered sales awaiting a buy-back
        var gains: [RealizedGain] = []
        let includeFees = feeTreatment == .includeInBasis

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
                var quantity = event.quantity
                // A buy's fee raises its cost basis (include-in-basis mode).
                var value = event.value + (includeFees ? event.fee : 0)
                let perShare = value / event.quantity
                // A buy after an uncovered sale first closes the short: the gain
                // (short-sale proceeds less buy-back cost) is struck here, dated
                // at the cover.
                while quantity > 0, !shorts.isEmpty {
                    let cover = min(quantity, shorts[0].remainingShares)
                    let proceeds = rounded(
                        shorts[0].remainingProceeds * cover / shorts[0].remainingShares, fraction)
                    let shortFee = rounded(
                        shorts[0].remainingFee * cover / shorts[0].remainingShares, fraction)
                    let coverCost = rounded(cover * perShare, fraction) + shortFee
                    gains.append(RealizedGain(
                        disposalDate: event.date, acquisitionDate: nil,
                        quantity: cover, proceeds: proceeds, costBasis: coverCost,
                        longTerm: nil))
                    shorts[0].remainingProceeds -= proceeds
                    shorts[0].remainingFee -= shortFee
                    shorts[0].remainingShares -= cover
                    quantity -= cover
                    value -= cover * perShare
                    if shorts[0].remainingShares == 0 { shorts.removeFirst() }
                }
                pooledShares += quantity
                pooledCost += value
            } else if event.quantity < 0 {
                let sharesSold = -event.quantity
                let proceeds = -event.value
                let proceedsPerShare = sharesSold != 0 ? proceeds / sharesSold : 0
                // A sale's fee raises the realised cost basis, spread across the
                // shares sold (include-in-basis mode).
                let feePerShare = (includeFees && sharesSold != 0) ? event.fee / sharesSold : 0
                let covered = min(sharesSold, max(pooledShares, 0))
                let uncovered = sharesSold - covered
                if covered > 0 {
                    let avg = pooledShares != 0 ? pooledCost / pooledShares : 0
                    let lotCost = avg * covered
                    gains.append(RealizedGain(
                        disposalDate: event.date, acquisitionDate: nil,
                        quantity: covered, proceeds: rounded(proceedsPerShare * covered, fraction),
                        costBasis: rounded(lotCost + covered * feePerShare, fraction), longTerm: nil))
                    pooledShares -= covered
                    pooledCost -= lotCost
                }
                // Sold more than the pool holds: open a short position. No gain
                // yet — it is struck when a later buy covers it.
                if uncovered > 0 {
                    shorts.append(MutableShort(
                        date: event.date, remainingShares: uncovered,
                        remainingProceeds: proceedsPerShare * uncovered,
                        remainingFee: uncovered * feePerShare))
                }
                if pooledShares <= 0 { pooledShares = 0; pooledCost = 0 }
            }
        }

        let openLots = pooledShares > 0
            ? [OpenLot(acquisitionDate: nil, quantity: pooledShares, costBasis: pooledCost)]
            : []
        let shortfall = shorts.reduce(Decimal(0)) { $0 + $1.remainingShares }
        return CostBasisResult(method: .average, openLots: openLots,
                               realizedGains: gains, shortQuantity: shortfall)
    }
}
