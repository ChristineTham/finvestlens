//
//  FinancialReview.swift
//  FinvestLens — FeatureUI
//
//  The Financial Review deck's data (docs/report-redesign.md §3.3): each
//  slide is one message — a kicker, an action title, two-to-four callouts,
//  one focused chart, and a footnote — built like a CFO's results
//  presentation. Slides appear only when they have meaningful data (the
//  dashboard's content-aware rule), and every headline has a deterministic
//  form so the deck reads well with Apple Intelligence off; the model only
//  ever *improves* a title, from the slide's own facts.
//
//  No new arithmetic: every figure comes from the existing memoised report
//  computations.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports
import FinvestLensIntelligence

// MARK: - Slide model

struct SlideCallout: Identifiable {
    let id = UUID()
    var label: String
    var value: String
    var delta: String?
    var deltaPositive: Bool?
}

struct WaterfallStep: Identifiable {
    enum Kind { case anchor, rise, fall }
    let id = UUID()
    var label: String
    var start: Decimal
    var end: Decimal
    var kind: Kind
}

struct CategoryBar: Identifiable {
    let id = UUID()
    var label: String
    var current: Decimal
    var prior: Decimal?
}

enum SlideChart {
    case netWorthLine([NetWorthPoint])
    case waterfall([WaterfallStep])
    case categoryBars([CategoryBar])
    case monthlyFlows([MonthlyFlow])
    case allocation([(symbol: String, value: Decimal)])
    case none
}

struct ReviewSlide: Identifiable {
    /// Stable slug — the insight cache key rides on it.
    var id: String
    var kicker: String
    /// The deterministic action title; the narrator may replace it.
    var headline: String
    var callouts: [SlideCallout]
    var chart: SlideChart
    var footnote: String
    var facts: ReviewSlideFacts
}

// MARK: - Builders

@MainActor
extension AppModel {

    /// The deck for a period: every slide with meaningful data, in the
    /// standard results-presentation order.
    func financialReviewSlides(from: Date, to: Date, label: String) -> [ReviewSlide] {
        guard book != nil else { return [] }
        let code = reportCurrency.mnemonic

        let current = incomeStatement(from: from, to: to)
        let calendar = Calendar.current
        let priorFrom = calendar.date(byAdding: .year, value: -1, to: from)
        let priorTo = calendar.date(byAdding: .year, value: -1, to: to)
        let prior: IncomeStatement? = {
            guard let priorFrom, let priorTo,
                  book?.transactions.contains(where: { $0.datePosted < from }) == true
            else { return nil }
            return incomeStatement(from: priorFrom, to: priorTo)
        }()

        let openingDate = from == .distantPast ? from : from.addingTimeInterval(-1)
        let opening = balanceSheet(asOf: openingDate)
        let closing = balanceSheet(asOf: to)

        var slides: [ReviewSlide] = []
        if let slide = highlightsSlide(from: from, to: to, label: label, code: code,
                                       current: current, opening: opening, closing: closing) {
            slides.append(slide)
        }
        if let slide = bridgeSlide(label: label, code: code, opening: opening,
                                   closing: closing, period: current) {
            slides.append(slide)
        }
        if let slide = flowSlide(section: .income, from: from, to: to, label: label,
                                 code: code, current: current, prior: prior) {
            slides.append(slide)
        }
        if let slide = flowSlide(section: .expenses, from: from, to: to, label: label,
                                 code: code, current: current, prior: prior) {
            slides.append(slide)
        }
        if let slide = cashFlowSlide(from: from, to: to, label: label, code: code,
                                     current: current) {
            slides.append(slide)
        }
        if let slide = portfolioSlide(to: to, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = dividendSlide(from: from, to: to, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = gainsSlide(from: from, to: to, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = positionSlide(to: to, label: label, code: code, closing: closing) {
            slides.append(slide)
        }
        return slides
    }

    // MARK: Formatting helpers (deterministic voice)

    private func money(_ value: Decimal, _ code: String) -> String {
        AmountFormat.string(value, code: code)
    }

    /// "$3.83m" — deck callouts breathe better compact.
    private func compact(_ value: Decimal, _ code: String) -> String {
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
            return "\(sign)\(money(abs(value), code))"
        }
    }

    private func percentDelta(_ current: Decimal, _ prior: Decimal) -> Decimal? {
        guard prior != 0 else { return nil }
        var result = (current - prior) / abs(prior) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, 1, .plain)
        return rounded
    }

    private func deltaText(_ percent: Decimal?) -> (String, Bool)? {
        guard let percent else { return nil }
        return ("\(percent >= 0 ? "+" : "")\(percent)% YoY", percent >= 0)
    }

    // MARK: Slides

    private func highlightsSlide(from: Date, to: Date, label: String, code: String,
                                 current: IncomeStatement?,
                                 opening: BalanceSheet?,
                                 closing: BalanceSheet?) -> ReviewSlide? {
        guard let closing else { return nil }
        let netWorth = closing.totalAssets - closing.totalLiabilities
        let openingNet = opening.map { $0.totalAssets - $0.totalLiabilities }
        let surplus = current?.netIncome ?? 0
        let income = current?.totalIncome ?? 0
        let savingsRate: Decimal? = income > 0 ? surplus / income * 100 : nil

        var callouts: [SlideCallout] = [
            SlideCallout(label: "Net worth", value: compact(netWorth, code)),
            SlideCallout(label: "Net surplus", value: compact(surplus, code),
                         deltaPositive: surplus >= 0),
        ]
        if let savingsRate {
            var rounded = Decimal(); var raw = savingsRate
            NSDecimalRound(&rounded, &raw, 0, .plain)
            callouts.append(SlideCallout(label: "Savings rate", value: "\(rounded)%"))
        }

        let months = max(12, Calendar.current.dateComponents([.month], from: from, to: to).month ?? 12)
        let series = netWorthSeries(months: min(months, 24), endingAt: min(to, AppModel.endOfToday()))

        let headline = surplus >= 0
            ? "Net worth \(compact(netWorth, code)) with a \(compact(surplus, code)) surplus"
            : "Net worth \(compact(netWorth, code)) after a \(compact(-surplus, code)) deficit"
        return ReviewSlide(
            id: "highlights",
            kicker: "Financial Review · \(label)",
            headline: headline,
            callouts: callouts,
            chart: .netWorthLine(series),
            footnote: "Net worth as at \(AppDateFormat.current.long(to)) · \(statementEntityName)",
            facts: {
                var figures: [(String, Decimal)] = [
                    ("Net worth", netWorth), ("Net surplus", surplus),
                    ("Income", income), ("Expenses", current?.totalExpenses ?? 0)]
                var deltas: [(String, Decimal)] = []
                if let openingNet {
                    figures.append(("Opening net worth", openingNet))
                    figures.append(("Change in net worth", netWorth - openingNet))
                    if let percent = percentDelta(netWorth, openingNet) {
                        deltas.append(("Net worth", percent))
                    }
                }
                if let savingsRate {
                    var rounded = Decimal(); var raw = savingsRate
                    NSDecimalRound(&rounded, &raw, 1, .plain)
                    figures.append(("Savings rate percent", rounded))
                }
                return ReviewSlideFacts(kicker: "Highlights", periodLabel: label,
                                        currencyCode: code, figures: figures,
                                        deltaPercents: deltas)
            }())
    }

    private func bridgeSlide(label: String, code: String,
                             opening: BalanceSheet?, closing: BalanceSheet?,
                             period: IncomeStatement?) -> ReviewSlide? {
        guard let opening, let closing, let period else { return nil }
        let openingNet = opening.totalAssets - opening.totalLiabilities
        let closingNet = closing.totalAssets - closing.totalLiabilities
        guard closingNet != openingNet else { return nil }
        let valuation = closingNet - openingNet - period.netIncome

        var steps: [WaterfallStep] = []
        var running = openingNet
        steps.append(WaterfallStep(label: "Opening", start: 0, end: openingNet, kind: .anchor))
        steps.append(WaterfallStep(label: "Income", start: running,
                                   end: running + period.totalIncome, kind: .rise))
        running += period.totalIncome
        steps.append(WaterfallStep(label: "Expenses", start: running - period.totalExpenses,
                                   end: running, kind: .fall))
        running -= period.totalExpenses
        steps.append(WaterfallStep(label: "Valuation & FX",
                                   start: valuation >= 0 ? running : running + valuation,
                                   end: valuation >= 0 ? running + valuation : running,
                                   kind: valuation >= 0 ? .rise : .fall))
        running += valuation
        steps.append(WaterfallStep(label: "Closing", start: 0, end: closingNet, kind: .anchor))

        let change = closingNet - openingNet
        let percent = percentDelta(closingNet, openingNet)
        let headline: String
        if let percent {
            headline = change >= 0
                ? "Net worth grew \(percent)% to \(compact(closingNet, code))"
                : "Net worth eased \(-percent)% to \(compact(closingNet, code))"
        } else {
            headline = "Net worth moved to \(compact(closingNet, code))"
        }
        return ReviewSlide(
            id: "bridge",
            kicker: "Net worth",
            headline: headline,
            callouts: [
                SlideCallout(label: "Opening", value: compact(openingNet, code)),
                SlideCallout(label: "Surplus", value: compact(period.netIncome, code),
                             deltaPositive: period.netIncome >= 0),
                SlideCallout(label: "Valuation & FX", value: compact(valuation, code),
                             deltaPositive: valuation >= 0),
                SlideCallout(label: "Closing", value: compact(closingNet, code)),
            ],
            chart: .waterfall(steps),
            footnote: "Valuation & FX derived as closing − opening − net surplus",
            facts: ReviewSlideFacts(
                kicker: "Net worth bridge", periodLabel: label, currencyCode: code,
                figures: [("Opening net worth", openingNet),
                          ("Income", period.totalIncome),
                          ("Expenses", period.totalExpenses),
                          ("Valuation and currency movement", valuation),
                          ("Change in net worth", change),
                          ("Closing net worth", closingNet)],
                deltaPercents: percent.map { [("Net worth", $0)] } ?? []))
    }

    private enum FlowSection { case income, expenses }

    /// Income or spending analysis: the statement layer's own captions as
    /// bars, current vs prior.
    private func flowSlide(section: FlowSection, from: Date, to: Date, label: String,
                           code: String, current: IncomeStatement?,
                           prior: IncomeStatement?) -> ReviewSlide? {
        guard let book, let current else { return nil }
        let lines = section == .income ? current.income : current.expenses
        let total = section == .income ? current.totalIncome : current.totalExpenses
        guard total != 0, !lines.isEmpty else { return nil }
        let priorLines = section == .income ? prior?.income : prior?.expenses
        let priorTotal = section == .income ? prior?.totalIncome : prior?.totalExpenses

        let builder = StatementBuilder(book: book)
        let forest = builder.captionForest(lineSets: [lines] + (priorLines.map { [$0] } ?? []))
        let ordered = StatementBuilder.sort(forest, by: .magnitude).prefix(6)
        let bars = ordered.map { node in
            CategoryBar(label: node.name,
                        current: (node.total.first ?? nil) ?? 0,
                        prior: node.total.count > 1 ? node.total[1] : nil)
        }

        let percent = priorTotal.flatMap { percentDelta(total, $0) }
        let noun = section == .income ? "Income" : "Spending"
        let top = ordered.first
        let headline: String
        if let percent, let priorTotal, priorTotal != 0 {
            let direction = percent >= 0 ? "up" : "down"
            headline = "\(noun) \(direction) \(abs(percent))% at \(compact(total, code))"
        } else if let top {
            headline = "\(noun) of \(compact(total, code)), led by \(top.name)"
        } else {
            headline = "\(noun) of \(compact(total, code))"
        }

        var callouts: [SlideCallout] = [
            SlideCallout(label: "Total \(noun.lowercased())", value: compact(total, code),
                         delta: deltaText(percent)?.0,
                         deltaPositive: deltaText(percent).map { section == .income ? $0.1 : !$0.1 }),
        ]
        if let top {
            let topValue = (top.total.first ?? nil) ?? 0
            callouts.append(SlideCallout(label: "Largest: \(top.name)",
                                         value: compact(topValue, code)))
            if total != 0 {
                var share = topValue / total * 100
                var rounded = Decimal()
                NSDecimalRound(&rounded, &share, 0, .plain)
                callouts.append(SlideCallout(label: "Share of total", value: "\(rounded)%"))
            }
        }

        var figures: [(String, Decimal)] = [("Total", total)]
        if let priorTotal, priorTotal != 0 {
            figures.append(("Prior period total", priorTotal))
        }
        figures.append(contentsOf: ordered.map { ($0.name, ($0.total.first ?? nil) ?? 0) })
        var deltas: [(String, Decimal)] = []
        if let percent { deltas.append(("Total", percent)) }

        return ReviewSlide(
            id: section == .income ? "income" : "spending",
            kicker: noun,
            headline: headline,
            callouts: callouts,
            chart: .categoryBars(Array(bars)),
            footnote: prior == nil ? "No prior-period comparison available"
                                   : "Prior period: one year earlier",
            facts: ReviewSlideFacts(kicker: noun, periodLabel: label, currencyCode: code,
                                    figures: figures, deltaPercents: deltas))
    }

    private func cashFlowSlide(from: Date, to: Date, label: String, code: String,
                               current: IncomeStatement?) -> ReviewSlide? {
        guard let months = categoryBreakdown(from: from, to: to)?.months,
              months.count >= 2 else { return nil }
        let net = months.reduce(Decimal(0)) { $0 + $1.income - $1.expenses }
        let average = net / Decimal(months.count)
        let positiveMonths = months.filter { $0.income >= $0.expenses }.count

        let headline = average >= 0
            ? "Cash flow positive in \(positiveMonths) of \(months.count) months"
            : "Cash flow negative on average across \(months.count) months"
        return ReviewSlide(
            id: "cashflow",
            kicker: "Cash flow",
            headline: headline,
            callouts: [
                SlideCallout(label: "Net for period", value: compact(net, code),
                             deltaPositive: net >= 0),
                SlideCallout(label: "Monthly average", value: compact(average, code),
                             deltaPositive: average >= 0),
                SlideCallout(label: "Positive months", value: "\(positiveMonths)/\(months.count)"),
            ],
            chart: .monthlyFlows(months),
            footnote: "Income less expenses, by calendar month",
            facts: ReviewSlideFacts(
                kicker: "Cash flow", periodLabel: label, currencyCode: code,
                figures: [("Net cash flow", net), ("Monthly average", average),
                          ("Months positive", Decimal(positiveMonths)),
                          ("Months in period", Decimal(months.count))]))
    }

    private func portfolioSlide(to: Date, label: String, code: String) -> ReviewSlide? {
        guard let portfolio = advancedPortfolio(asOf: to),
              portfolio.totalValue > 0 else { return nil }
        let valued = portfolio.holdings
            .filter { ($0.marketValue ?? 0) > 0 }
            .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
        guard !valued.isEmpty else { return nil }

        let winners = portfolio.holdings.compactMap { holding -> (String, Decimal)? in
            guard let gain = holding.unrealizedGain else { return nil }
            return (holding.symbol, gain)
        }
        let best = winners.max { $0.1 < $1.1 }
        let worst = winners.min { $0.1 < $1.1 }

        var callouts: [SlideCallout] = [
            SlideCallout(label: "Market value", value: compact(portfolio.totalValue, code)),
            SlideCallout(label: "Unrealised gain", value: compact(portfolio.totalUnrealized, code),
                         deltaPositive: portfolio.totalUnrealized >= 0),
        ]
        if let best { callouts.append(SlideCallout(label: "Best: \(best.0)",
                                                   value: compact(best.1, code),
                                                   deltaPositive: best.1 >= 0)) }
        if let worst, worst.0 != best?.0 {
            callouts.append(SlideCallout(label: "Weakest: \(worst.0)",
                                         value: compact(worst.1, code),
                                         deltaPositive: worst.1 >= 0))
        }

        let top = valued.first!
        let headline = "Portfolio of \(compact(portfolio.totalValue, code)) led by \(top.symbol)"
        return ReviewSlide(
            id: "portfolio",
            kicker: "Portfolio",
            headline: headline,
            callouts: callouts,
            chart: .allocation(valued.prefix(12).map { ($0.symbol, $0.marketValue ?? 0) }),
            footnote: "Valued at the most recent recorded prices · \(portfolio.method.displayName) basis",
            facts: ReviewSlideFacts(
                kicker: "Portfolio", periodLabel: label, currencyCode: code,
                figures: [("Market value", portfolio.totalValue),
                          ("Cost basis", portfolio.totalCost),
                          ("Unrealised gain", portfolio.totalUnrealized)]
                    + (best.map { [("Best holding \($0.0)", $0.1)] } ?? [])
                    + (worst.map { [("Weakest holding \($0.0)", $0.1)] } ?? [])))
    }

    private func dividendSlide(from: Date, to: Date, label: String, code: String) -> ReviewSlide? {
        guard let document = dividendFrankingDocument(from: from, to: to, periodLabel: label)
        else { return nil }
        let franked = document.kpis.first { $0.label == "Franked" }?.amount ?? 0
        let unfranked = document.kpis.first { $0.label == "Unfranked" }?.amount ?? 0
        let credits = document.kpis.first { $0.label == "Franking credits" }?.amount ?? 0
        let total = franked + unfranked
        guard total != 0 || credits != 0 else { return nil }

        // Per-security bars from the document's own sections.
        var bySecurity: [String: Decimal] = [:]
        for section in document.sections where section.title.hasSuffix("dividends") {
            for row in section.rows {
                bySecurity[row.label, default: 0] += row.amount ?? 0
            }
        }
        let bars = bySecurity.sorted { $0.value > $1.value }.prefix(8)
            .map { CategoryBar(label: $0.key, current: $0.value, prior: nil) }

        let headline = "Dividends of \(compact(total, code)) carrying \(compact(credits, code)) in credits"
        return ReviewSlide(
            id: "dividends",
            kicker: "Dividends & franking",
            headline: headline,
            callouts: [
                SlideCallout(label: "Franked", value: compact(franked, code)),
                SlideCallout(label: "Unfranked", value: compact(unfranked, code)),
                SlideCallout(label: "Franking credits", value: compact(credits, code)),
                SlideCallout(label: "Grossed-up", value: compact(total + credits, code)),
            ],
            chart: .categoryBars(Array(bars)),
            footnote: "Classified from the Dividends income tree",
            facts: ReviewSlideFacts(
                kicker: "Dividends", periodLabel: label, currencyCode: code,
                figures: [("Franked dividends", franked), ("Unfranked dividends", unfranked),
                          ("Franking credits", credits), ("Grossed-up total", total + credits)]))
    }

    private func gainsSlide(from: Date, to: Date, label: String, code: String) -> ReviewSlide? {
        guard let report = capitalGains(from: from, to: to), !report.lines.isEmpty
        else { return nil }
        let total = report.totalGain
        var bySymbol: [String: Decimal] = [:]
        for line in report.lines { bySymbol[line.symbol, default: 0] += line.gain }
        let ranked = bySymbol.sorted { abs($0.value) > abs($1.value) }
        let bars = ranked.prefix(8).map {
            CategoryBar(label: $0.key, current: $0.value, prior: nil)
        }
        let gains = report.lines.filter { $0.gain > 0 }.count
        let losses = report.lines.filter { $0.gain < 0 }.count

        let headline = total >= 0
            ? "Realised gains of \(compact(total, code)) across \(report.lines.count) disposals"
            : "Realised losses of \(compact(-total, code)) across \(report.lines.count) disposals"
        return ReviewSlide(
            id: "gains",
            kicker: "Capital gains",
            headline: headline,
            callouts: [
                SlideCallout(label: "Realised", value: compact(total, code),
                             deltaPositive: total >= 0),
                SlideCallout(label: "Disposals", value: "\(report.lines.count)"),
                SlideCallout(label: "Gains / losses", value: "\(gains) / \(losses)"),
            ],
            chart: .categoryBars(Array(bars)),
            footnote: "\(report.method.displayName) cost basis",
            facts: ReviewSlideFacts(
                kicker: "Capital gains", periodLabel: label, currencyCode: code,
                figures: [("Realised gain", total), ("Disposals", Decimal(report.lines.count))]
                    + ranked.prefix(5).map { ($0.key, $0.value) }))
    }

    private func positionSlide(to: Date, label: String, code: String,
                               closing: BalanceSheet?) -> ReviewSlide? {
        guard let closing else { return nil }
        let net = closing.totalAssets - closing.totalLiabilities
        guard closing.totalAssets != 0 else { return nil }

        var debtShare = closing.totalLiabilities / closing.totalAssets * 100
        var debtRounded = Decimal()
        NSDecimalRound(&debtRounded, &debtShare, 1, .plain)

        // Liquidity: cash-class assets over average monthly spending (12m).
        let yearBack = Calendar.current.date(byAdding: .year, value: -1, to: to) ?? to
        let spend = incomeStatement(from: yearBack, to: to)?.totalExpenses ?? 0
        let monthlySpend = spend / 12
        let cashAssets: Decimal = {
            guard let book else { return 0 }
            return closing.assets.reduce(Decimal(0)) { sum, line in
                guard let account = book.account(with: line.id),
                      account.type == .bank || account.type == .cash else { return sum }
                return sum + line.amount
            }
        }()
        var liquidityMonths: Decimal? = nil
        if monthlySpend > 0 {
            var months = cashAssets / monthlySpend
            var rounded = Decimal()
            NSDecimalRound(&rounded, &months, 1, .plain)
            liquidityMonths = rounded
        }

        var callouts: [SlideCallout] = [
            SlideCallout(label: "Assets", value: compact(closing.totalAssets, code)),
            SlideCallout(label: "Liabilities", value: compact(closing.totalLiabilities, code)),
            SlideCallout(label: "Debt to assets", value: "\(debtRounded)%"),
        ]
        if let liquidityMonths {
            callouts.append(SlideCallout(label: "Cash covers", value: "\(liquidityMonths) months"))
        }

        let headline = "Liabilities are \(debtRounded)% of \(compact(closing.totalAssets, code)) in assets"
        return ReviewSlide(
            id: "position",
            kicker: "Financial position",
            headline: headline,
            callouts: callouts,
            chart: .categoryBars([
                CategoryBar(label: "Assets", current: closing.totalAssets, prior: nil),
                CategoryBar(label: "Liabilities", current: closing.totalLiabilities, prior: nil),
                CategoryBar(label: "Net worth", current: net, prior: nil),
            ]),
            footnote: "Cash cover = bank and cash balances over average monthly spending (trailing 12 months)",
            facts: ReviewSlideFacts(
                kicker: "Financial position", periodLabel: label, currencyCode: code,
                figures: [("Assets", closing.totalAssets),
                          ("Liabilities", closing.totalLiabilities),
                          ("Net worth", net),
                          ("Debt to assets percent", debtRounded)]))
    }

    // MARK: Insights (Apple Intelligence, cached)

    /// The narrator's story for a slide, cached per (slide, book revision).
    /// Returns `nil` — leaving the deterministic headline — when Apple
    /// Intelligence is unavailable or declines.
    func reviewStory(for slide: ReviewSlide) async -> ReviewSlideStory? {
        let key = "review.story:\(slide.id):\(bookRevision):\(slide.facts.periodLabel)"
        if let cached = reviewStoryCache[key] { return cached }
        guard isIntelligenceAvailable else { return nil }
        guard #available(macOS 26.0, iOS 26.0, *) else { return nil }
        do {
            let story = try await ReviewNarrator.story(facts: slide.facts)
            reviewStoryCache[key] = story
            return story
        } catch {
            return nil
        }
    }
}
