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
    @Bindable var model: AppModel

    /// The timescale that drives every panel. This financial year by default.
    @State private var period: ReportPeriod = .currentFinancialYear
    /// Selected sector value for the allocation donut's hover tooltip.
    @State private var allocationValue: Double?
    /// Per-holding value over the timescale, for the performance area.
    @State private var perfSeries: [PerfPoint] = []
    @State private var perfHover: PerfHover?

    private var code: String { model.reportCurrency.mnemonic }

    private enum Panel: Hashable {
        case netWorth, income, expenses, cashflow, allocation, performance
        case alerts, bills, accounts

        var minColumns: Int {
            switch self {
            case .netWorth, .income, .expenses, .cashflow, .alerts: 1
            case .allocation, .performance, .bills: 2
            case .accounts: 3
            }
        }
    }

    var body: some View {
        let range = model.resolve(period)
        return GeometryReader { geo in
            let columns = columnCount(for: geo.size.width)
            let portfolio = model.portfolio(asOf: min(range.to, Date()))
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
        let all: [Panel] = [.netWorth, .income, .expenses, .cashflow,
                            .allocation, .performance, .alerts, .bills, .accounts]
        return all.filter { panel in
            guard panel.minColumns <= columns else { return false }
            switch panel {
            case .allocation, .performance: return hasInvestments
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
        case .netWorth: netWorthCard(asOf: min(range.to, Date()))
        case .income: incomeCard(range)
        case .expenses: expensesCard(range)
        case .cashflow: cashflowCard(range)
        case .allocation: allocationCard(portfolio)
        case .performance: performanceCard()
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

    // MARK: Investment performance over the timescale (stacked area, hover)

    struct PerfPoint: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let symbol: String
        let value: Double
        let returnPct: Double?
    }
    struct PerfHover: Equatable {
        let symbol: String
        let returnPct: Double?
        let value: Double
        let at: CGPoint
    }

    /// Values each holding at ~monthly points across the timescale (up to today)
    /// so the area shows each security's contribution over the period.
    private func computePerformance(_ range: (from: Date, to: Date)) async -> [PerfPoint] {
        let end = min(range.to, Date())
        let start = range.from == .distantPast ? end.addingTimeInterval(-365 * 86_400) : range.from
        guard end > start else { return [] }
        let samples = 12
        var points: [PerfPoint] = []
        for step in 0...samples {
            let fraction = Double(step) / Double(samples)
            let date = start.addingTimeInterval(end.timeIntervalSince(start) * fraction)
            if let pf = model.portfolio(asOf: date) {
                for holding in pf.holdings where (holding.marketValue ?? 0) > 0 {
                    points.append(PerfPoint(date: date, symbol: holding.symbol,
                                            value: asDouble(holding.marketValue ?? 0),
                                            returnPct: holding.gainFraction))
                }
            }
            await Task.yield()
        }
        return points
    }

    /// Stacking order (largest holdings at the bottom), so the hover band lookup
    /// matches how the chart stacks the areas.
    private var perfOrder: [String] {
        let totals = Dictionary(grouping: perfSeries, by: \.symbol)
            .mapValues { $0.map(\.value).max() ?? 0 }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    @ViewBuilder
    private func performanceCard() -> some View {
        Card("Performance", systemImage: "chart.line.uptrend.xyaxis.circle") {
            if perfSeries.isEmpty {
                Text("No priced holdings to value over this period.")
                    .scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                Chart(perfSeries) { point in
                    AreaMark(x: .value("Date", point.date),
                             y: .value("Value", point.value))
                        .foregroundStyle(by: .value("Security", point.symbol))
                }
                .chartForegroundStyleScale(domain: perfOrder)
                .chartLegend(.hidden)
                .chartYAxis { AxisMarks(format: .currency(code: code).notation(.compactName)) }
                .frame(height: 220)
                .chartOverlay { proxy in perfHoverOverlay(proxy) }
                .overlay(alignment: .topLeading) {
                    if let perfHover {
                        perfTooltip(perfHover)
                            .offset(x: perfHover.at.x + 8, y: perfHover.at.y - 8)
                    }
                }
                .accessibilityLabel("Each holding's value over \(model.label(for: period)); hover for its return")
            }
        }
    }

    private func perfHoverOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case let .active(location) = phase,
                          let frame = proxy.plotFrame.map({ geo[$0] }) else {
                        perfHover = nil
                        return
                    }
                    let x = location.x - frame.minX
                    let y = location.y - frame.minY
                    guard let date: Date = proxy.value(atX: x),
                          let yValue: Double = proxy.value(atY: y) else { perfHover = nil; return }
                    perfHover = band(at: date, yValue: yValue, location: location)
                }
        }
    }

    /// The stacked band the cursor is over: at the nearest sampled date, walk
    /// holdings in stacking order accumulating value until the cursor's y falls
    /// inside a band.
    private func band(at date: Date, yValue: Double, location: CGPoint) -> PerfHover? {
        guard yValue >= 0 else { return nil }
        let dates = Set(perfSeries.map(\.date))
        guard let nearest = dates.min(by: { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) })
        else { return nil }
        var cumulative = 0.0
        for symbol in perfOrder {
            guard let point = perfSeries.first(where: { $0.date == nearest && $0.symbol == symbol }) else { continue }
            if yValue >= cumulative && yValue < cumulative + point.value {
                return PerfHover(symbol: symbol, returnPct: point.returnPct, value: point.value, at: location)
            }
            cumulative += point.value
        }
        return nil
    }

    private func perfTooltip(_ hover: PerfHover) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(hover.symbol).fontWeight(.semibold)
            if let pct = hover.returnPct {
                Text(pct, format: .percent.precision(.fractionLength(1)))
                    .foregroundStyle(pct < 0 ? .red : .green)
            }
            Text(AmountFormat.string(Decimal(hover.value), code: code)).monospacedDigit()
        }
        .scaledFont(.caption)
        .padding(6)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 3)
        .allowsHitTesting(false)
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
                        Text(bill.dueDate, format: .dateTime.month().day())
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
