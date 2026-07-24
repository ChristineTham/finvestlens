//
//  InvestmentReview.swift
//  FinvestLens — FeatureUI
//
//  The Investment Review deck: the portfolio presented the way a fund
//  factsheet and a brokerage performance summary present it — overview,
//  allocation with concentration, mark-to-market leaders, income, realised
//  gains with the long/short-term split, and a return decomposition. Built
//  on the same slide machinery (and the same grounded-facts + validator
//  contract) as the Financial Review.
//
//  Every figure comes from the existing verified computations: the advanced
//  portfolio (money in/out, per-holding income, return fraction), the
//  capital-gains engine, and the dividend classification. No new arithmetic.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports
import FinvestLensIntelligence

@MainActor
extension AppModel {

    /// The investment deck for a period. Empty when the book holds no
    /// valued securities.
    func investmentReviewSlides(from: Date, to: Date, label: String) -> [ReviewSlide] {
        guard let portfolio = advancedPortfolio(asOf: to),
              portfolio.holdings.contains(where: { ($0.marketValue ?? 0) != 0 })
        else { return [] }
        let code = reportCurrency.mnemonic

        var slides: [ReviewSlide] = []
        if let slide = investmentOverviewSlide(portfolio, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = allocationSlide(portfolio, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = leadersSlide(portfolio, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = investmentIncomeSlide(portfolio, from: from, to: to,
                                             label: label, code: code) {
            slides.append(slide)
        }
        if let slide = realisedSlide(from: from, to: to, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = decompositionSlide(portfolio, label: label, code: code) {
            slides.append(slide)
        }
        return slides
    }

    private func compactAmount(_ value: Decimal, _ code: String) -> String {
        let double = NSDecimalNumber(decimal: value).doubleValue
        let symbol = AmountFormat.string(0, code: code).first.map(String.init) ?? ""
        let magnitude = abs(double)
        let sign = double < 0 ? "−" : ""
        switch magnitude {
        case 1_000_000...:
            return "\(sign)\(symbol)\(String(format: "%.2f", magnitude / 1_000_000))m"
        case 10_000...:
            return "\(sign)\(symbol)\(String(format: "%.0f", magnitude / 1_000))k"
        default:
            return "\(sign)\(AmountFormat.string(abs(value), code: code))"
        }
    }

    private func roundedPercent(_ fraction: Double, places: Int = 1) -> Decimal {
        var value = Decimal(fraction * 100)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, places, .plain)
        return rounded
    }

    // MARK: Slides

    /// Factsheet page one: value, cost, unrealised, total return.
    private func investmentOverviewSlide(_ portfolio: AdvancedPortfolio,
                                         label: String, code: String) -> ReviewSlide? {
        let valued = portfolio.holdings
            .filter { ($0.marketValue ?? 0) > 0 }
            .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
        guard !valued.isEmpty else { return nil }

        var callouts: [SlideCallout] = [
            SlideCallout(label: "Market value", value: compactAmount(portfolio.totalValue, code)),
            SlideCallout(label: "Cost basis", value: compactAmount(portfolio.totalCost, code)),
            SlideCallout(label: "Unrealised", value: compactAmount(portfolio.totalUnrealized, code),
                         deltaPositive: portfolio.totalUnrealized >= 0),
        ]
        var figures: [(String, Decimal)] = [
            ("Market value", portfolio.totalValue),
            ("Cost basis", portfolio.totalCost),
            ("Unrealised gain", portfolio.totalUnrealized),
        ]
        var headline = "Portfolio valued at \(compactAmount(portfolio.totalValue, code))"
        if let returnFraction = portfolio.totalReturnFraction {
            let percent = roundedPercent(returnFraction)
            callouts.append(SlideCallout(label: "Total return", value: "\(percent)%",
                                         deltaPositive: percent >= 0))
            figures.append(("Total return percent", percent))
            headline = percent >= 0
                ? "Portfolio of \(compactAmount(portfolio.totalValue, code)) returning \(percent)% on money in"
                : "Portfolio of \(compactAmount(portfolio.totalValue, code)) down \(-percent)% on money in"
        }

        let bars = valued.prefix(8).map {
            CategoryBar(label: $0.symbol, current: $0.marketValue ?? 0, prior: nil)
        }
        return ReviewSlide(
            id: "inv.overview",
            kicker: "Investment Review · \(label)",
            headline: headline,
            callouts: callouts,
            chart: .categoryBars(Array(bars)),
            footnote: "Valued at the most recent recorded prices · \(portfolio.method.displayName) basis · return = (unrealised + realised + income) over money in",
            facts: ReviewSlideFacts(kicker: "Portfolio overview", periodLabel: label,
                                    currencyCode: code, figures: figures))
    }

    /// Allocation + the factsheet's concentration read.
    private func allocationSlide(_ portfolio: AdvancedPortfolio,
                                 label: String, code: String) -> ReviewSlide? {
        let valued = portfolio.holdings
            .filter { ($0.marketValue ?? 0) > 0 }
            .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
        guard valued.count >= 2, portfolio.totalValue > 0 else { return nil }

        let top = valued[0]
        let topShare = roundedPercent(
            NSDecimalNumber(decimal: (top.marketValue ?? 0) / portfolio.totalValue).doubleValue)
        let topFive = valued.prefix(5).reduce(Decimal(0)) { $0 + ($1.marketValue ?? 0) }
        let topFiveShare = roundedPercent(
            NSDecimalNumber(decimal: topFive / portfolio.totalValue).doubleValue)

        return ReviewSlide(
            id: "inv.allocation",
            kicker: "Allocation",
            headline: "\(valued.count) holdings; the top five are \(topFiveShare)% of the portfolio",
            callouts: [
                SlideCallout(label: "Holdings", value: "\(valued.count)"),
                SlideCallout(label: "Largest: \(top.symbol)", value: "\(topShare)%"),
                SlideCallout(label: "Top five", value: "\(topFiveShare)%"),
            ],
            chart: .allocation(valued.prefix(12).map { ($0.symbol, $0.marketValue ?? 0) }),
            footnote: "Share of market value · concentration is the factsheet's first risk read",
            facts: ReviewSlideFacts(
                kicker: "Allocation and concentration", periodLabel: label, currencyCode: code,
                figures: [("Number of holdings", Decimal(valued.count)),
                          ("Largest holding percent", topShare),
                          ("Top five percent", topFiveShare)]
                    + valued.prefix(5).map { ($0.symbol, $0.marketValue ?? 0) }))
    }

    /// Mark-to-market winners and losers.
    private func leadersSlide(_ portfolio: AdvancedPortfolio,
                              label: String, code: String) -> ReviewSlide? {
        let judged = portfolio.holdings
            .compactMap { holding -> (String, Decimal)? in
                guard let gain = holding.unrealizedGain, gain != 0 else { return nil }
                return (holding.symbol, gain)
            }
            .sorted { $0.1 > $1.1 }
        guard let best = judged.first, let worst = judged.last, judged.count >= 2
        else { return nil }

        let bars = (judged.prefix(4) + judged.suffix(2))
            .map { CategoryBar(label: $0.0, current: $0.1, prior: nil) }
        let headline = best.1 >= abs(worst.1)
            ? "\(best.0) leads with \(compactAmount(best.1, code)) unrealised"
            : "\(worst.0) weighs with \(compactAmount(worst.1, code)) unrealised"

        return ReviewSlide(
            id: "inv.leaders",
            kicker: "Performance",
            headline: headline,
            callouts: [
                SlideCallout(label: "Best: \(best.0)", value: compactAmount(best.1, code),
                             deltaPositive: true),
                SlideCallout(label: "Weakest: \(worst.0)", value: compactAmount(worst.1, code),
                             deltaPositive: worst.1 >= 0),
                SlideCallout(label: "Unrealised total",
                             value: compactAmount(portfolio.totalUnrealized, code),
                             deltaPositive: portfolio.totalUnrealized >= 0),
            ],
            chart: .categoryBars(Array(bars)),
            footnote: "Unrealised gain and loss per holding, at latest recorded prices",
            facts: ReviewSlideFacts(
                kicker: "Winners and losers", periodLabel: label, currencyCode: code,
                figures: [("Unrealised total", portfolio.totalUnrealized)]
                    + judged.prefix(4).map { ($0.0, $0.1) }
                    + judged.suffix(2).map { ($0.0, $0.1) }))
    }

    /// Income: the period's dividends/distributions (classified), with
    /// lifetime income per holding as context.
    private func investmentIncomeSlide(_ portfolio: AdvancedPortfolio,
                                       from: Date, to: Date,
                                       label: String, code: String) -> ReviewSlide? {
        guard let document = dividendFrankingDocument(from: from, to: to, periodLabel: label)
        else { return nil }
        let franked = document.kpis.first { $0.label == "Franked" }?.amount ?? 0
        let unfranked = document.kpis.first { $0.label == "Unfranked" }?.amount ?? 0
        let credits = document.kpis.first { $0.label == "Franking credits" }?.amount ?? 0
        let periodIncome = franked + unfranked
        guard periodIncome != 0 else { return nil }

        var bySecurity: [String: Decimal] = [:]
        for section in document.sections where section.title.hasSuffix("dividends") {
            for row in section.rows { bySecurity[row.label, default: 0] += row.amount ?? 0 }
        }
        let bars = bySecurity.sorted { $0.value > $1.value }.prefix(8)
            .map { CategoryBar(label: $0.key, current: $0.value, prior: nil) }

        var callouts: [SlideCallout] = [
            SlideCallout(label: "Period income", value: compactAmount(periodIncome, code)),
            SlideCallout(label: "Franking credits", value: compactAmount(credits, code)),
        ]
        var figures: [(String, Decimal)] = [
            ("Period income", periodIncome),
            ("Franked", franked), ("Unfranked", unfranked),
            ("Franking credits", credits),
        ]
        if portfolio.totalValue > 0 {
            let yield = roundedPercent(
                NSDecimalNumber(decimal: periodIncome / portfolio.totalValue).doubleValue)
            callouts.append(SlideCallout(label: "Yield on value", value: "\(yield)%"))
            figures.append(("Income yield percent", yield))
        }

        return ReviewSlide(
            id: "inv.income",
            kicker: "Income",
            headline: "Investment income of \(compactAmount(periodIncome, code)) for \(label)",
            callouts: callouts,
            chart: .categoryBars(Array(bars)),
            footnote: "Dividends and distributions classified from the Dividends income tree · yield on closing market value",
            facts: ReviewSlideFacts(kicker: "Investment income", periodLabel: label,
                                    currencyCode: code, figures: figures))
    }

    /// Realised gains for the period, with the CGT-relevant term split.
    private func realisedSlide(from: Date, to: Date,
                               label: String, code: String) -> ReviewSlide? {
        guard let report = capitalGains(from: from, to: to), !report.lines.isEmpty
        else { return nil }
        let longTerm = report.lines.filter { $0.longTerm == true }
            .reduce(Decimal(0)) { $0 + $1.gain }
        let shortTerm = report.lines.filter { $0.longTerm == false }
            .reduce(Decimal(0)) { $0 + $1.gain }

        var bySymbol: [String: Decimal] = [:]
        for line in report.lines { bySymbol[line.symbol, default: 0] += line.gain }
        let bars = bySymbol.sorted { abs($0.value) > abs($1.value) }.prefix(8)
            .map { CategoryBar(label: $0.key, current: $0.value, prior: nil) }

        let headline = report.totalGain >= 0
            ? "Realised \(compactAmount(report.totalGain, code)) across \(report.lines.count) disposals"
            : "Realised a \(compactAmount(-report.totalGain, code)) loss across \(report.lines.count) disposals"
        return ReviewSlide(
            id: "inv.realised",
            kicker: "Realised gains",
            headline: headline,
            callouts: [
                SlideCallout(label: "Realised", value: compactAmount(report.totalGain, code),
                             deltaPositive: report.totalGain >= 0),
                SlideCallout(label: "Held > 1 year", value: compactAmount(longTerm, code),
                             deltaPositive: longTerm >= 0),
                SlideCallout(label: "Held ≤ 1 year", value: compactAmount(shortTerm, code),
                             deltaPositive: shortTerm >= 0),
                SlideCallout(label: "Disposals", value: "\(report.lines.count)"),
            ],
            chart: .categoryBars(Array(bars)),
            footnote: "\(report.method.displayName) cost basis · the over-a-year split is the CGT-discount boundary",
            facts: ReviewSlideFacts(
                kicker: "Realised gains", periodLabel: label, currencyCode: code,
                figures: [("Realised gain", report.totalGain),
                          ("Held over one year", longTerm),
                          ("Held one year or less", shortTerm),
                          ("Disposals", Decimal(report.lines.count))]))
    }

    /// Where the return came from: income + realised + unrealised over
    /// money in — the brokerage performance-summary decomposition.
    private func decompositionSlide(_ portfolio: AdvancedPortfolio,
                                    label: String, code: String) -> ReviewSlide? {
        guard portfolio.totalMoneyIn > 0 else { return nil }
        let gain = portfolio.totalUnrealized + portfolio.totalRealized + portfolio.totalIncome

        var callouts: [SlideCallout] = [
            SlideCallout(label: "Money in", value: compactAmount(portfolio.totalMoneyIn, code)),
            SlideCallout(label: "Money out", value: compactAmount(portfolio.totalMoneyOut, code)),
            SlideCallout(label: "Total gain", value: compactAmount(gain, code),
                         deltaPositive: gain >= 0),
        ]
        var figures: [(String, Decimal)] = [
            ("Money in", portfolio.totalMoneyIn),
            ("Money out", portfolio.totalMoneyOut),
            ("Income", portfolio.totalIncome),
            ("Realised gain", portfolio.totalRealized),
            ("Unrealised gain", portfolio.totalUnrealized),
            ("Total gain", gain),
        ]
        if let returnFraction = portfolio.totalReturnFraction {
            let percent = roundedPercent(returnFraction)
            callouts.append(SlideCallout(label: "Return on money in", value: "\(percent)%",
                                         deltaPositive: percent >= 0))
            figures.append(("Return percent", percent))
        }

        return ReviewSlide(
            id: "inv.decomposition",
            kicker: "Return decomposition",
            headline: "Gains of \(compactAmount(gain, code)) on \(compactAmount(portfolio.totalMoneyIn, code)) invested",
            callouts: callouts,
            chart: .categoryBars([
                CategoryBar(label: "Income", current: portfolio.totalIncome, prior: nil),
                CategoryBar(label: "Realised", current: portfolio.totalRealized, prior: nil),
                CategoryBar(label: "Unrealised", current: portfolio.totalUnrealized, prior: nil),
            ]),
            footnote: "Gain = income + realised + unrealised · GnuCash's money-in return model",
            facts: ReviewSlideFacts(kicker: "Return decomposition", periodLabel: label,
                                    currencyCode: code, figures: figures))
    }
}
