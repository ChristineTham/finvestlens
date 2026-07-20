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

    private var code: String { model.reportCurrency.mnemonic }

    /// Panels in priority order. `minColumns` is the layout width (in columns)
    /// below which the panel is dropped — the essentials survive at one column.
    private enum Panel: Hashable {
        case netWorth, incomeExpense, cashflow, allocation, performance
        case alerts, bills, accounts

        var minColumns: Int {
            switch self {
            case .netWorth, .incomeExpense, .cashflow, .alerts: 1
            case .allocation, .performance, .bills: 2
            case .accounts: 3
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let columns = columnCount(for: geo.size.width)
            let range = model.resolve(period)
            let portfolio = model.portfolio(asOf: range.to)
            ScrollView {
                masonry(columns: columns, range: range, portfolio: portfolio)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem {
                PeriodSelector(model: model, period: $period)
            }
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        max(1, min(3, Int(width / 380)))
    }

    /// The panels to show at `columns` columns: priority order, gated by
    /// `minColumns` and by whether their data exists.
    private func panels(columns: Int, portfolio: Portfolio?) -> [Panel] {
        let hasInvestments = !(portfolio?.holdings.isEmpty ?? true)
        let all: [Panel] = [.netWorth, .incomeExpense, .cashflow,
                            .allocation, .performance, .alerts, .bills, .accounts]
        return all.filter { panel in
            guard panel.minColumns <= columns else { return false }
            switch panel {
            case .allocation, .performance: return hasInvestments
            default: return true
            }
        }
    }

    /// Independent columns (masonry), so panels of different heights don't leave
    /// the gaps a row-aligned grid would. Priority order is preserved down each
    /// column via round-robin.
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
        // Net worth is a "right now" figure: cap the as-of at today so a period
        // ending in the future (e.g. the current financial year) doesn't trail
        // off into flat, dataless months.
        case .netWorth: netWorthCard(asOf: min(range.to, Date()))
        case .incomeExpense: incomeExpenseCard(range)
        case .cashflow: cashflowCard(range)
        case .allocation: allocationCard(portfolio)
        case .performance: performanceCard(portfolio)
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

    // MARK: Income & loss by category

    private func incomeExpenseCard(_ range: (from: Date, to: Date)) -> some View {
        let breakdown = model.categoryBreakdown(from: range.from, to: range.to)
        let net = (breakdown?.totalIncome ?? 0) - (breakdown?.totalExpenses ?? 0)
        return Card("Income & Expenses", systemImage: "arrow.left.arrow.right") {
            HStack(alignment: .firstTextBaseline) {
                Text(net < 0 ? "Net loss" : "Net income").scaledFont(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(AmountFormat.string(net, code: code))
                    .scaledFont(.title2, weight: .semibold, design: .rounded).monospacedDigit()
                    .foregroundStyle(net < 0 ? .red : .green)
            }
            if let breakdown, !(breakdown.incomeSlices.isEmpty && breakdown.expenseSlices.isEmpty) {
                let rows = categoryRows(income: breakdown.incomeSlices, expense: breakdown.expenseSlices)
                Chart(rows) { row in
                    BarMark(x: .value("Amount", asDouble(row.amount)),
                            y: .value("Category", row.name))
                        .foregroundStyle(row.isIncome ? Color.green : Color.red)
                }
                .chartXAxis { AxisMarks(format: .currency(code: code).notation(.compactName)) }
                .frame(height: CGFloat(rows.count) * 22 + 20)
                .accessibilityLabel("Income and expenses by category for \(model.label(for: period))")
            } else {
                Text("No income or expenses in this period.")
                    .scaledFont(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Top income (positive) and expense (negative) categories, largest first.
    private func categoryRows(income: [ReportLine], expense: [ReportLine]) -> [CategoryRow] {
        let inc = income.prefix(4).map { CategoryRow(name: $0.name, amount: $0.amount, isIncome: true) }
        let exp = expense.prefix(5).map { CategoryRow(name: $0.name, amount: -$0.amount, isIncome: false) }
        return Array(inc) + Array(exp)
    }

    private struct CategoryRow: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let amount: Decimal
        let isIncome: Bool
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
            // No budget: the period's income-vs-expense flow, month by month.
            let breakdown = model.categoryBreakdown(from: range.from, to: range.to)
            Card("Cashflow", systemImage: "arrow.up.arrow.down") {
                if let months = breakdown?.months, months.count >= 1 {
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

    // MARK: Investment allocation

    private struct AllocationSlice: Identifiable, Hashable {
        var id: String { symbol }
        let symbol: String
        let value: Decimal
    }

    /// The largest `top` holdings by market value; everything else folded into a
    /// single "Other" slice, so the donut and its legend stay legible for a book
    /// that holds dozens of securities.
    private func allocationSlices(_ portfolio: Portfolio?, top: Int = 8) -> [AllocationSlice] {
        let valued = (portfolio?.holdings ?? [])
            .filter { ($0.marketValue ?? 0) > 0 }
            .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
        var slices = valued.prefix(top).map { AllocationSlice(symbol: $0.symbol, value: $0.marketValue ?? 0) }
        let other = valued.dropFirst(top).reduce(Decimal(0)) { $0 + ($1.marketValue ?? 0) }
        if other > 0 { slices.append(AllocationSlice(symbol: "Other", value: other)) }
        return slices
    }

    @ViewBuilder
    private func allocationCard(_ portfolio: Portfolio?) -> some View {
        let slices = allocationSlices(portfolio)
        Card("Allocation", systemImage: "chart.pie") {
            if slices.isEmpty {
                Text("No valued holdings.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                Chart(slices) { slice in
                    SectorMark(angle: .value("Value", asDouble(slice.value)),
                               innerRadius: .ratio(0.6), angularInset: 1.5)
                        .cornerRadius(3)
                        .foregroundStyle(by: .value("Security", slice.symbol))
                }
                .frame(height: 240)
                .accessibilityLabel("Investment allocation: top holdings by value")
            }
        }
    }

    // MARK: Investment performance by security

    @ViewBuilder
    private func performanceCard(_ portfolio: Portfolio?) -> some View {
        let holdings = (portfolio?.holdings ?? []).filter { $0.gain != nil }
            .sorted { ($0.gain ?? 0) > ($1.gain ?? 0) }
        Card("Performance", systemImage: "chart.line.uptrend.xyaxis.circle") {
            if holdings.isEmpty {
                Text("No priced holdings to value.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(holdings) { holding in
                    HStack {
                        Text(holding.symbol).fontWeight(.medium)
                        Spacer()
                        if let fraction = holding.gainFraction {
                            Text(fraction, format: .percent.precision(.fractionLength(1)))
                                .scaledFont(.caption).monospacedDigit()
                                .foregroundStyle((holding.gain ?? 0) < 0 ? .red : .green)
                        }
                        Text(AmountFormat.string(holding.gain ?? 0, code: code))
                            .monospacedDigit()
                            .foregroundStyle((holding.gain ?? 0) < 0 ? .red : .green)
                            .frame(width: 90, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(holding.symbol), \(AmountFormat.spoken(holding.gain ?? 0, code: code))")
                }
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
                        Text(bill.dueDate, format: .dateTime.month().day())
                            .scaledFont(.caption).foregroundStyle(.secondary)
                        Text(AmountFormat.string(bill.amount, code: code)).monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Helpers

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
