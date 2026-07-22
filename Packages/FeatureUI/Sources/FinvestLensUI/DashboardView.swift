//
//  DashboardView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
import FinvestLensEngine
import FinvestLensReports

/// The home dashboard: a responsive masonry of prioritised panels that fills the
/// available width, all driven by one timescale selector (`FR-PLAN-08`). Narrow
/// windows show the essentials; wider ones reveal more panels down the priority
/// list. Investment panels appear only when the book holds securities.
struct DashboardView: View {
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel

    /// The timescale that drives every panel. This financial year by default.
    @State private var period: ReportPeriod = .currentFinancialYear
    /// Selected sector value for the allocation donut's hover tooltip.
    @State private var allocationValue: Double?
    /// Per-holding value over the timescale, for the performance area.
    @State private var perfSeries: [PerfPoint] = []
    @State private var perfHover: PerfHover?

    private var code: String { model.reportCurrency.mnemonic }

    /// "As of now", pinned to the end of today so it is stable across a session:
    /// `Date()` changes every call, which would defeat the report memo cache by
    /// making every panel's cache key unique on each body pass.
    private var todayCap: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 3600)
    }

    private enum Panel: Hashable {
        case netWorth, income, expenses, cashflow, savingsRate, allocation, performance
        case spendingTrend, topMovers, goals, recentActivity, composition
        case alerts, bills, accounts

        var minColumns: Int {
            switch self {
            case .netWorth, .income, .expenses, .cashflow, .savingsRate, .alerts: 1
            case .allocation, .performance, .spendingTrend, .topMovers, .goals, .recentActivity, .bills: 2
            case .composition, .accounts: 3
            }
        }
    }

    var body: some View {
        let range = model.resolve(period)
        return GeometryReader { geo in
            let columns = columnCount(for: geo.size.width)
            let portfolio = model.portfolio(asOf: min(range.to, todayCap))
            ScrollView {
                masonry(columns: columns, range: range, portfolio: portfolio)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem { PeriodSelector(model: model, period: $period) }
        }
        .task(id: RangeKey(from: range.from, to: range.to)) {
            perfSeries = await computePerformance(range)
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        max(1, min(3, Int(width / 380)))
    }

    private func panels(columns: Int, portfolio: Portfolio?) -> [Panel] {
        let hasInvestments = !(portfolio?.holdings.isEmpty ?? true)
        let all: [Panel] = [.netWorth, .income, .expenses, .cashflow, .savingsRate,
                            .allocation, .performance, .spendingTrend, .topMovers,
                            .goals, .recentActivity, .composition, .alerts, .bills, .accounts]
        return all.filter { panel in
            guard panel.minColumns <= columns else { return false }
            switch panel {
            case .allocation, .performance: return hasInvestments
            case .goals: return !model.savingsGoals.isEmpty
            default: return true
            }
        }
    }

    @ViewBuilder
    private func masonry(columns: Int, range: (from: Date, to: Date), portfolio: Portfolio?) -> some View {
        let shown = panels(columns: columns, portfolio: portfolio)
        HStack(alignment: .top, spacing: 16) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: 16) {
                    ForEach(Array(shown.enumerated()).filter { $0.offset % columns == column }, id: \.element) { _, panel in
                        view(for: panel, range: range, portfolio: portfolio)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private func view(for panel: Panel, range: (from: Date, to: Date), portfolio: Portfolio?) -> some View {
        switch panel {
        case .netWorth: netWorthCard(asOf: min(range.to, todayCap))
        case .income: incomeCard(range)
        case .expenses: expensesCard(range)
        case .cashflow: cashflowCard(range)
        case .savingsRate: savingsRateCard(range)
        case .allocation: allocationCard(portfolio)
        case .performance: performanceCard()
        case .spendingTrend: spendingTrendCard(range)
        case .topMovers: topMoversCard(range)
        case .goals: goalsCard
        case .recentActivity: recentActivityCard
        case .composition: compositionCard(asOf: min(range.to, todayCap))
        case .alerts: alertsCard
        case .bills: billsCard
        case .accounts: accountsCard
        }
    }

    // MARK: Net worth

    private func netWorthCard(asOf: Date) -> some View {
        let series = model.netWorthSeries(months: 12, endingAt: asOf)
        let current = series.last?.netWorth ?? 0
        return Card("Net Worth", systemImage: "chart.line.uptrend.xyaxis") {
            Text(AmountFormat.string(current, code: code))
                .scaledFont(.largeTitle, weight: .bold, design: .rounded).monospacedDigit()
                .foregroundStyle(current < 0 ? .red : .primary)
                .accessibilityLabel("Net worth")
                .accessibilityValue(AmountFormat.spoken(current, code: code))
            if series.count >= 2 {
                Chart(series) { point in
                    AreaMark(x: .value("Month", point.date), y: .value("Net worth", asDouble(point.netWorth)))
                        .foregroundStyle(.tint.opacity(0.15))
                    LineMark(x: .value("Month", point.date), y: .value("Net worth", asDouble(point.netWorth)))
                }
                .frame(height: 120)
                .chartXAxis { AxisMarks(values: .stride(by: .month, count: 3)) }
                .accessibilityLabel("Net worth trend over the last 12 months")
            }
        }
    }

    // MARK: Income & Expense treemaps

    private func incomeCard(_ range: (from: Date, to: Date)) -> some View {
        let statement = model.incomeStatement(from: range.from, to: range.to)
        return treemapCard(title: "Income", systemImage: "arrow.down.circle",
                           lines: statement?.income ?? [], total: statement?.totalIncome ?? 0,
                           empty: "No income in this period.")
    }

    private func expensesCard(_ range: (from: Date, to: Date)) -> some View {
        let statement = model.incomeStatement(from: range.from, to: range.to)
        return treemapCard(title: "Expenses", systemImage: "arrow.up.circle",
                           lines: statement?.expenses ?? [], total: statement?.totalExpenses ?? 0,
                           empty: "No expenses in this period.")
    }

    private func treemapCard(title: String, systemImage: String,
                             lines: [ReportLine], total: Decimal, empty: String) -> some View {
        let items = lines
            .filter { $0.amount > 0 }
            .sorted { $0.amount > $1.amount }
            .map { line in
                TreemapItem(id: line.id.hexString, name: line.name,
                            value: asDouble(line.amount),
                            detail: AmountFormat.string(line.amount, code: code))
            }
        return Card(title, systemImage: systemImage) {
            HStack {
                Text("Total").scaledFont(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(AmountFormat.string(total, code: code))
                    .scaledFont(.title3, weight: .semibold, design: .rounded).monospacedDigit()
            }
            if items.isEmpty {
                Text(empty).scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                Treemap(items: items)
                    .frame(height: 220)
                    .accessibilityLabel("\(title) by account for \(model.label(for: period))")
            }
        }
    }

    // MARK: Cashflow vs budget / by month

    @ViewBuilder
    private func cashflowCard(_ range: (from: Date, to: Date)) -> some View {
        if let budget = model.budgets.first {
            let actuals = model.budgetActuals(budget)
            Card("Cashflow vs Budget", systemImage: "chart.bar.doc.horizontal") {
                if actuals.isEmpty {
                    Text("No budget lines set.").scaledFont(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(actuals.prefix(6)) { actual in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(actual.accountName).lineLimit(1)
                                Spacer()
                                Text("\(AmountFormat.string(actual.actual, code: code)) / \(AmountFormat.string(actual.effectiveBudget, code: code))")
                                    .scaledFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            ProgressView(value: min(1, max(0, actual.fractionUsed ?? 0)))
                                .tint(actual.isOverBudget ? .red : .accentColor)
                        }
                    }
                }
            }
        } else {
            let breakdown = model.categoryBreakdown(from: range.from, to: range.to)
            Card("Cashflow", systemImage: "arrow.up.arrow.down") {
                if let months = breakdown?.months, !months.isEmpty {
                    Chart {
                        ForEach(months) { flow in
                            BarMark(x: .value("Month", flow.month, unit: .month),
                                    y: .value("Income", asDouble(flow.income)))
                                .foregroundStyle(Color.green)
                                .position(by: .value("Kind", "Income"))
                            BarMark(x: .value("Month", flow.month, unit: .month),
                                    y: .value("Expenses", asDouble(flow.expenses)))
                                .foregroundStyle(Color.red)
                                .position(by: .value("Kind", "Expenses"))
                        }
                    }
                    .chartYAxis { AxisMarks(format: .currency(code: code).notation(.compactName)) }
                    .frame(height: 150)
                    .accessibilityLabel("Monthly income and expenses for \(model.label(for: period))")
                } else {
                    Text("No cashflow in this period.").scaledFont(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Investment allocation (all holdings, hover for detail)

    private struct AllocationSlice: Identifiable, Hashable {
        var id: String { symbol }
        let symbol: String
        let value: Decimal
        let start: Double   // cumulative value where this slice begins
    }

    private func allocationSlices(_ portfolio: Portfolio?) -> (slices: [AllocationSlice], total: Double) {
        let valued = (portfolio?.holdings ?? [])
            .filter { ($0.marketValue ?? 0) > 0 }
            .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
        var cumulative = 0.0
        let slices = valued.map { holding -> AllocationSlice in
            let slice = AllocationSlice(symbol: holding.symbol, value: holding.marketValue ?? 0, start: cumulative)
            cumulative += asDouble(holding.marketValue ?? 0)
            return slice
        }
        return (slices, cumulative)
    }

    @ViewBuilder
    private func allocationCard(_ portfolio: Portfolio?) -> some View {
        let (slices, total) = allocationSlices(portfolio)
        let selected = allocationValue.flatMap { value in
            slices.first { value >= $0.start && value < $0.start + asDouble($0.value) }
        }
        Card("Allocation", systemImage: "chart.pie") {
            if slices.isEmpty {
                Text("No valued holdings.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                Chart(slices) { slice in
                    SectorMark(angle: .value("Value", asDouble(slice.value)),
                               innerRadius: .ratio(0.62), angularInset: 1)
                        .cornerRadius(2)
                        .foregroundStyle(by: .value("Security", slice.symbol))
                        .opacity(selected == nil || selected?.symbol == slice.symbol ? 1 : 0.35)
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: $allocationValue)
                .frame(height: 240)
                // Selected holding's detail sits in the donut hole.
                .overlay {
                    if let selected, total > 0 {
                        VStack(spacing: 2) {
                            Text(selected.symbol).fontWeight(.semibold).lineLimit(1)
                            Text(asDouble(selected.value) / total, format: .percent.precision(.fractionLength(1)))
                                .foregroundStyle(.secondary)
                            Text(AmountFormat.string(selected.value, code: code))
                                .monospacedDigit().scaledFont(.caption)
                        }
                        .padding(6)
                    } else {
                        Text("Hover a slice").scaledFont(.caption).foregroundStyle(.tertiary)
                    }
                }
                .accessibilityLabel("Investment allocation by security; hover a slice for its share and value")
            }
        }
    }

    // MARK: Investment performance over the timescale (rebased return lines, hover)

    /// One holding's (or the portfolio's) return at a sample date, rebased so the
    /// start of the timescale reads 0%.
    struct PerfPoint: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let series: String       // security symbol, or "Portfolio"
        let returnPct: Double     // fraction: 0.12 == +12%
        let isPortfolio: Bool
    }
    /// The date the cursor is over; the tooltip reads every series at that date.
    struct PerfHover: Equatable {
        let date: Date
        let at: CGPoint
    }

    private static let portfolioSeries = "Portfolio"

    /// Each currently-held security's price return relative to the start of the
    /// timescale (0% at the start), plus the value-weighted portfolio return in
    /// which each holding's move contributes by its current weight. Driven purely
    /// by price history, so it shows exactly how prices moved over the period.
    private func computePerformance(_ range: (from: Date, to: Date)) async -> [PerfPoint] {
        let end = min(range.to, todayCap)
        let start = range.from == .distantPast ? end.addingTimeInterval(-365 * 86_400) : range.from
        guard end > start, let endPf = model.portfolio(asOf: end) else { return [] }

        // The basket: securities held now, each with a valid price at the start of
        // the window (so a return can be rebased) — and their current weights.
        struct Holding { let id: GncGUID; let symbol: String; let startPrice: Double; let weight: Double }
        let totalEnd = endPf.holdings.reduce(0.0) { $0 + asDouble($1.marketValue ?? 0) }
        guard totalEnd > 0 else { return [] }
        let basket: [Holding] = endPf.holdings.compactMap { h in
            guard (h.marketValue ?? 0) > 0,
                  let sp = model.securityUnitPrice(accountID: h.id, on: start),
                  sp > 0 else { return nil }
            return Holding(id: h.id, symbol: h.symbol, startPrice: asDouble(sp),
                           weight: asDouble(h.marketValue ?? 0) / totalEnd)
        }
        guard !basket.isEmpty else { return [] }

        let samples = 26
        var points: [PerfPoint] = []
        for step in 0...samples {
            let fraction = Double(step) / Double(samples)
            let date = start.addingTimeInterval(end.timeIntervalSince(start) * fraction)
            var overall = 0.0
            for h in basket {
                guard let price = model.securityUnitPrice(accountID: h.id, on: date) else { continue }
                let ret = asDouble(price) / h.startPrice - 1
                points.append(PerfPoint(date: date, series: h.symbol, returnPct: ret, isPortfolio: false))
                overall += h.weight * ret
            }
            points.append(PerfPoint(date: date, series: Self.portfolioSeries,
                                    returnPct: overall, isPortfolio: true))
            await Task.yield()
        }
        return points
    }

    private var perfHoldingPoints: [PerfPoint] { perfSeries.filter { !$0.isPortfolio } }
    private var perfPortfolioPoints: [PerfPoint] { perfSeries.filter(\.isPortfolio) }

    @ViewBuilder
    private func performanceCard() -> some View {
        Card("Performance", systemImage: "chart.line.uptrend.xyaxis.circle") {
            if perfSeries.isEmpty {
                Text("No priced holdings to value over this period.")
                    .scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    // Individual holdings: thin, de-emphasised — the divergence is
                    // the story, identity comes from the hover tooltip.
                    ForEach(perfHoldingPoints) { p in
                        LineMark(x: .value("Date", p.date), y: .value("Return", p.returnPct),
                                 series: .value("Security", p.series))
                            .foregroundStyle(by: .value("Security", p.series))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .opacity(0.45)
                    }
                    // The portfolio: bold, on top, in the foreground colour.
                    ForEach(perfPortfolioPoints) { p in
                        LineMark(x: .value("Date", p.date), y: .value("Return", p.returnPct),
                                 series: .value("Series", Self.portfolioSeries))
                            .foregroundStyle(.primary)
                            .lineStyle(StrokeStyle(lineWidth: 3))
                    }
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .chartLegend(.hidden)
                .chartYAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0))) }
                .frame(height: 220)
                .chartOverlay { proxy in perfHoverOverlay(proxy) }
                .overlay(alignment: .topLeading) {
                    if let perfHover {
                        perfTooltip(at: perfHover.date)
                            .fixedSize()
                            .offset(x: min(perfHover.at.x + 8, 40), y: 8)
                    }
                }
                .accessibilityLabel("Each holding's return over \(model.label(for: period)), rebased to the start; hover for all holdings and the portfolio")
            }
        }
    }

    private func perfHoverOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case let .active(location) = phase,
                          let frame = proxy.plotFrame.map({ geo[$0] }),
                          let date: Date = proxy.value(atX: location.x - frame.minX),
                          let nearest = nearestPerfDate(to: date) else {
                        perfHover = nil
                        return
                    }
                    perfHover = PerfHover(date: nearest, at: location)
                }
        }
    }

    private func nearestPerfDate(to date: Date) -> Date? {
        Set(perfSeries.map(\.date))
            .min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    /// Every series' return at the hovered date: the portfolio first (bold), then
    /// each holding sorted best-to-worst.
    private func perfTooltip(at date: Date) -> some View {
        let atDate = perfSeries.filter { $0.date == date }
        let portfolio = atDate.first(where: \.isPortfolio)
        let holdings = atDate.filter { !$0.isPortfolio }.sorted { $0.returnPct > $1.returnPct }
        return VStack(alignment: .leading, spacing: 2) {
            Text(dateFormat.full(date))
                .scaledFont(.caption2).foregroundStyle(.secondary)
            if let portfolio {
                perfRow(name: "Portfolio", pct: portfolio.returnPct, bold: true)
            }
            Divider()
            let columns = holdings.count > 12 ? 2 : 1
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns),
                      alignment: .leading, spacing: 1) {
                ForEach(holdings) { p in perfRow(name: p.series, pct: p.returnPct, bold: false) }
            }
        }
        .scaledFont(.caption2)
        .padding(8)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .allowsHitTesting(false)
    }

    private func perfRow(name: String, pct: Double, bold: Bool) -> some View {
        HStack(spacing: 6) {
            Text(name).fontWeight(bold ? .bold : .regular)
            Spacer(minLength: 8)
            Text(pct, format: .percent.precision(.fractionLength(1)))
                .fontWeight(bold ? .bold : .regular)
                .monospacedDigit()
                .foregroundStyle(pct < 0 ? .red : .green)
        }
        .frame(minWidth: 96)
    }

    // MARK: Savings rate

    private func savingsRateCard(_ range: (from: Date, to: Date)) -> some View {
        let statement = model.incomeStatement(from: range.from, to: range.to)
        let income = statement?.totalIncome ?? 0
        let net = statement?.netIncome ?? 0
        let rate = income > 0 ? asDouble(net) / asDouble(income) : 0
        return Card("Savings Rate", systemImage: "percent") {
            if income <= 0 {
                Text("No income in this period.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                Gauge(value: max(0, min(1, rate))) {
                    EmptyView()
                } currentValueLabel: {
                    Text(rate, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(rate < 0 ? .red : .primary)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(rate < 0 ? .red : .green)
                .frame(maxWidth: .infinity)
                Text("Kept \(AmountFormat.string(net, code: code)) of \(AmountFormat.string(income, code: code))")
                    .scaledFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    // MARK: Spending trend

    private func spendingTrendCard(_ range: (from: Date, to: Date)) -> some View {
        let months = model.categoryBreakdown(from: range.from, to: range.to)?.months ?? []
        let average = months.isEmpty ? Decimal(0)
            : months.reduce(Decimal(0)) { $0 + $1.expenses } / Decimal(months.count)
        return Card("Spending Trend", systemImage: "chart.xyaxis.line") {
            if months.count < 2 {
                Text("Not enough data to trend.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(months) { flow in
                        BarMark(x: .value("Month", flow.month, unit: .month),
                                y: .value("Spent", asDouble(flow.expenses)))
                            .foregroundStyle(Color.red.opacity(0.7))
                    }
                    RuleMark(y: .value("Average", asDouble(average)))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("avg \(AmountFormat.string(average, code: code))")
                                .scaledFont(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYAxis { AxisMarks(format: .currency(code: code).notation(.compactName)) }
                .frame(height: 150)
                .accessibilityLabel("Monthly spending versus the period average")
            }
        }
    }

    // MARK: Top movers

    private func topMoversCard(_ range: (from: Date, to: Date)) -> some View {
        let statement = model.incomeStatement(from: range.from, to: range.to)
        let income = (statement?.income ?? []).sorted { $0.amount > $1.amount }.prefix(3)
        let expenses = (statement?.expenses ?? []).sorted { $0.amount > $1.amount }.prefix(4)
        return Card("Top Movers", systemImage: "arrow.up.arrow.down.circle") {
            if income.isEmpty && expenses.isEmpty {
                Text("No activity in this period.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(income)) { line in moverRow(line.name, line.amount, isIncome: true) }
                ForEach(Array(expenses)) { line in moverRow(line.name, line.amount, isIncome: false) }
            }
        }
    }

    private func moverRow(_ name: String, _ amount: Decimal, isIncome: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isIncome ? "arrow.down.left" : "arrow.up.right")
                .foregroundStyle(isIncome ? .green : .red).imageScale(.small)
            Text(name).lineLimit(1)
            Spacer()
            Text(AmountFormat.string(amount, code: code))
                .monospacedDigit().foregroundStyle(isIncome ? .green : .primary)
        }
    }

    // MARK: Savings goals

    private var goalsCard: some View {
        Card("Savings Goals", systemImage: "target") {
            ForEach(model.savingsGoals) { goal in
                let fraction = goal.targetAmount > 0
                    ? asDouble(goal.savedAmount) / asDouble(goal.targetAmount) : 0
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(goal.name).lineLimit(1)
                        Spacer()
                        Text("\(AmountFormat.string(goal.savedAmount, code: code)) / \(AmountFormat.string(goal.targetAmount, code: code))")
                            .scaledFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(1, max(0, fraction)))
                        .tint(fraction >= 1 ? .green : .accentColor)
                }
            }
        }
    }

    // MARK: Recent activity

    private var recentActivityCard: some View {
        let recent = model.journalRows(forAccountID: nil)
            .filter { $0.isHeading && $0.date != nil }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(7)
        return Card("Recent Activity", systemImage: "clock") {
            if recent.isEmpty {
                Text("No transactions yet.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(recent)) { row in
                    HStack(spacing: 8) {
                        Text(dateFormat.monthDay(row.date ?? Date()))
                            .scaledFont(.caption).foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Text(row.text.isEmpty ? "—" : row.text).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: Net worth composition

    private func compositionCard(asOf: Date) -> some View {
        let sheet = model.balanceSheet(asOf: asOf)
        return Card("Net Worth Composition", systemImage: "chart.bar.fill") {
            if let sheet {
                let rows: [(String, Decimal, Color)] = [
                    ("Assets", sheet.totalAssets, .green),
                    ("Liabilities", sheet.totalLiabilities, .red),
                    ("Equity", sheet.totalEquity, .blue),
                ]
                Chart(rows, id: \.0) { row in
                    BarMark(x: .value("Amount", asDouble(row.1)), y: .value("Kind", row.0))
                        .foregroundStyle(row.2)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(AmountFormat.string(row.1, code: code))
                                .scaledFont(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                }
                .chartXAxis { AxisMarks(format: .currency(code: code).notation(.compactName)) }
                .frame(height: 130)
                .accessibilityLabel("Assets, liabilities and equity")
            } else {
                Text("No data.").scaledFont(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Alerts

    private var alertsCard: some View {
        let alerts = model.alerts()
        return Card("Alerts", systemImage: "bell.badge") {
            if alerts.isEmpty {
                Label("Nothing needs attention", systemImage: "checkmark.circle")
                    .foregroundStyle(.green).scaledFont(.callout)
            } else {
                ForEach(alerts) { alert in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: alert.severity))
                            .foregroundStyle(color(for: alert.severity))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alert.title).fontWeight(.medium)
                            Text(alert.message).scaledFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(severityWord(alert.severity)) alert. \(alert.title). \(alert.message)")
                }
            }
        }
    }

    // MARK: Accounts

    private var accountsCard: some View {
        Card("Accounts", systemImage: "list.bullet") {
            if model.accountTree.isEmpty {
                Text("No accounts yet.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.accountTree) { node in
                    Button {
                        model.selectedAccountID = node.id
                    } label: {
                        HStack {
                            Text(node.name)
                            Spacer()
                            Text(AmountFormat.string(node.balance, code: node.currencyCode))
                                .monospacedDigit()
                                .foregroundStyle(node.balance < 0 ? .red : .primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Bills

    private var billsCard: some View {
        let bills = model.billReminders().filter { $0.status != .paid }.prefix(6)
        return Card("Upcoming Bills", systemImage: "calendar") {
            if bills.isEmpty {
                Text("No upcoming bills.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(bills)) { bill in
                    HStack {
                        Text(bill.name).lineLimit(1)
                        Spacer()
                        Text(dateFormat.monthDay(bill.dueDate))
                            .scaledFont(.caption).foregroundStyle(.secondary)
                        Text(AmountFormat.string(bill.amount, code: code)).monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private struct RangeKey: Hashable { let from: Date; let to: Date }

    private func asDouble(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }
    private func icon(for s: AlertSeverity) -> String {
        switch s { case .critical: "exclamationmark.octagon.fill"; case .warning: "exclamationmark.triangle.fill"; case .info: "info.circle.fill" }
    }
    private func color(for s: AlertSeverity) -> Color {
        switch s { case .critical: .red; case .warning: .orange; case .info: .blue }
    }
    private func severityWord(_ s: AlertSeverity) -> String {
        switch s { case .critical: "Critical"; case .warning: "Warning"; case .info: "Information" }
    }
}

/// A titled dashboard card.
private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .scaledFont(.headline).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
