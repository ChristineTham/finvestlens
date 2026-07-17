//
//  AverageBalanceReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// How finely the average-balance report slices its date range.
public enum AverageBalanceStep: String, Codable, Sendable, CaseIterable, Identifiable {
    case day, week, twoWeeks, month, quarter, halfYear, year

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .twoWeeks: "Fortnight"
        case .month: "Month"
        case .quarter: "Quarter"
        case .halfYear: "Half-year"
        case .year: "Year"
        }
    }

    /// The calendar increment from one interval boundary to the next.
    var components: DateComponents {
        switch self {
        case .day: DateComponents(day: 1)
        case .week: DateComponents(day: 7)
        case .twoWeeks: DateComponents(day: 14)
        case .month: DateComponents(month: 1)
        case .quarter: DateComponents(month: 3)
        case .halfYear: DateComponents(month: 6)
        case .year: DateComponents(year: 1)
        }
    }
}

/// One interval of the average-balance report: the daily-balance statistics
/// and the flows that moved the balance over the interval (`FR-RPT-03`).
public struct AverageBalanceInterval: Identifiable, Hashable, Sendable {
    public var id: Date { start }
    public var start: Date
    public var end: Date
    /// Mean of the end-of-day balances across every day in the interval.
    public var average: Decimal
    public var maximum: Decimal
    public var minimum: Decimal
    /// Sum of the inflows (positive postings) within the interval.
    public var gain: Decimal
    /// Sum of the outflows (negative postings), as a positive number.
    public var loss: Decimal
    /// Net change over the interval (gain − loss).
    public var profit: Decimal
}

/// The average-balance report over a set of accounts (GnuCash's "Average
/// Balance"): per interval, the daily-weighted average balance with its range,
/// plus the inflows/outflows that produced it.
public struct AverageBalanceReport: Sendable {
    public var currencyCode: String
    public var accountNames: [String]
    public var step: AverageBalanceStep
    public var from: Date
    public var to: Date
    public var intervals: [AverageBalanceInterval]

    /// Mean of the interval averages, weighted by each interval's day count —
    /// i.e. the daily-weighted average over the whole range.
    public var overallAverage: Decimal? {
        guard !intervals.isEmpty else { return nil }
        let total = intervals.reduce(Decimal(0)) { $0 + $1.average * Decimal($1.dayCount) }
        let days = intervals.reduce(0) { $0 + $1.dayCount }
        return days == 0 ? nil : total / Decimal(days)
    }
    public var totalGain: Decimal { intervals.reduce(0) { $0 + $1.gain } }
    public var totalLoss: Decimal { intervals.reduce(0) { $0 + $1.loss } }
    public var totalProfit: Decimal { intervals.reduce(0) { $0 + $1.profit } }
}

public extension AverageBalanceInterval {
    /// Whole calendar days the interval spans (inclusive of both ends).
    var dayCount: Int {
        let secs = end.timeIntervalSince(start)
        return max(1, Int((secs / 86_400).rounded()) + 1)
    }
}

public extension FinancialReports {

    /// The daily-weighted average balance of `accounts` over `[from, to]`,
    /// sliced by `step` (GnuCash's "Average Balance", `FR-RPT-03`).
    ///
    /// For each calendar day the combined end-of-day balance of the selected
    /// accounts is sampled (each account valued in `currency`); an interval's
    /// **average** is the mean of those daily balances, its **maximum** and
    /// **minimum** their range. **Gain**/**loss** sum the interval's inflows and
    /// outflows; **profit** is the net. A balance carried in from before `from`
    /// seeds the running total without counting as a flow.
    static func averageBalance(
        _ book: Book,
        accounts: [Account],
        currency: Commodity,
        from: Date,
        to: Date,
        step: AverageBalanceStep = .month,
        calendar: Calendar = .current
    ) -> AverageBalanceReport {
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)

        func value(_ native: Decimal, _ commodity: Commodity, on day: Date) -> Decimal {
            if native == 0 { return 0 }
            if commodity == currency { return native }
            return book.convert(native, from: commodity, to: currency, on: day) ?? 0
        }

        // Per-account: postings inside the range (sorted by day), the balance
        // carried in from before the range, and a cursor into the postings.
        struct AccountState {
            let account: Account
            var running: Decimal
            var events: [(day: Date, delta: Decimal)]
            var cursor: Int = 0
        }
        var states: [AccountState] = accounts.map { account in
            var prior = Decimal(0)
            var events: [(Date, Decimal)] = []
            for transaction in book.transactions {
                let day = calendar.startOfDay(for: transaction.datePosted)
                for split in transaction.splits
                where split.account === account && split.reconcileState != .voided {
                    if day < fromDay { prior += split.quantity }
                    else if day <= toDay { events.append((day, split.quantity)) }
                }
            }
            events.sort { $0.0 < $1.0 }
            return AccountState(account: account, running: prior, events: events)
        }

        guard fromDay <= toDay, !states.isEmpty else {
            return AverageBalanceReport(
                currencyCode: currency.mnemonic, accountNames: accounts.map(\.name),
                step: step, from: from, to: to, intervals: [])
        }

        // Interval boundaries: step from the first day until past the last.
        var boundaries: [Date] = []
        var boundary = fromDay
        while boundary <= toDay {
            boundaries.append(boundary)
            boundary = calendar.date(byAdding: step.components, to: boundary)!
        }

        var intervals: [AverageBalanceInterval] = []
        var boundaryIndex = 0
        var dailyBalances: [Decimal] = []
        var flows: [Decimal] = []

        func closeInterval(start: Date, endExclusive: Date) {
            let end = calendar.date(byAdding: .day, value: -1, to: endExclusive)!
            let count = dailyBalances.count
            let average = count > 0
                ? dailyBalances.reduce(0, +) / Decimal(count) : 0
            let gain = flows.filter { $0 > 0 }.reduce(0, +)
            let loss = flows.filter { $0 < 0 }.reduce(0, +)
            intervals.append(AverageBalanceInterval(
                start: start, end: end,
                average: average,
                maximum: currency.round(dailyBalances.max() ?? 0),
                minimum: currency.round(dailyBalances.min() ?? 0),
                gain: currency.round(gain),
                loss: currency.round(-loss),
                profit: currency.round(gain + loss)))
            dailyBalances = []
            flows = []
        }

        var day = fromDay
        while day <= toDay {
            // Cross any boundaries we have reached, closing finished intervals.
            while boundaryIndex + 1 < boundaries.count, day >= boundaries[boundaryIndex + 1] {
                closeInterval(start: boundaries[boundaryIndex],
                              endExclusive: boundaries[boundaryIndex + 1])
                boundaryIndex += 1
            }
            // Apply this day's postings to running balances and interval flows.
            for index in states.indices {
                while states[index].cursor < states[index].events.count,
                      states[index].events[states[index].cursor].day == day {
                    let delta = states[index].events[states[index].cursor].delta
                    states[index].running += delta
                    flows.append(value(delta, states[index].account.commodity, on: day))
                    states[index].cursor += 1
                }
            }
            // Sample the combined end-of-day balance.
            var balance = Decimal(0)
            for state in states {
                balance += value(state.running, state.account.commodity, on: day)
            }
            dailyBalances.append(balance)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        // Close the final, open interval up to the day after the last.
        closeInterval(start: boundaries[boundaryIndex],
                      endExclusive: calendar.date(byAdding: .day, value: 1, to: toDay)!)

        return AverageBalanceReport(
            currencyCode: currency.mnemonic, accountNames: accounts.map(\.name),
            step: step, from: from, to: to, intervals: intervals)
    }
}
