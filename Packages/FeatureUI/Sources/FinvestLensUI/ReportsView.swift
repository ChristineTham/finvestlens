//
//  ReportsView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
import FinvestLensEngine
import FinvestLensReports

/// A tabbed reports view: Balance Sheet, Income Statement, and a Net-Worth chart.
struct ReportsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ReportKind = .balanceSheet

    enum ReportKind: String, CaseIterable, Identifiable {
        case balanceSheet = "Balance Sheet"
        case incomeStatement = "Income Statement"
        case netWorth = "Net Worth"
        case cashFlow = "Cash Flow"
        case portfolio = "Portfolio"
        case capitalGains = "Capital Gains"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // A menu picker keeps a small, fixed width; a segmented control
                // grows with the number of reports and clips inside the sheet.
                HStack {
                    Picker("Report", selection: $selection) {
                        ForEach(ReportKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                }
                .padding()
                Divider()
                switch selection {
                case .balanceSheet: BalanceSheetView(model: model)
                case .incomeStatement: IncomeStatementView(model: model)
                case .netWorth: NetWorthChartView(model: model)
                case .cashFlow: CashFlowView(model: model)
                case .portfolio: PortfolioView(model: model)
                case .capitalGains: CapitalGainsView(model: model)
                }
            }
            .navigationTitle("Reports")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 440)
    }
}

private struct TotalRow: View {
    let label: String
    let amount: Decimal
    let code: String
    var emphasised = false

    var body: some View {
        HStack {
            Text(label).fontWeight(emphasised ? .bold : .regular)
            Spacer()
            Text(AmountFormat.string(amount, code: code))
                .monospacedDigit()
                .fontWeight(emphasised ? .bold : .regular)
        }
    }
}

private struct LineRows: View {
    let lines: [ReportLine]
    let code: String
    var body: some View {
        ForEach(lines) { line in
            HStack {
                Text(line.name).foregroundStyle(.secondary)
                Spacer()
                Text(AmountFormat.string(line.amount, code: code)).monospacedDigit()
            }
        }
    }
}

private struct BalanceSheetView: View {
    @Bindable var model: AppModel
    var body: some View {
        if let sheet = model.balanceSheet() {
            List {
                Section("Assets") {
                    LineRows(lines: sheet.assets, code: sheet.currencyCode)
                    TotalRow(label: "Total Assets", amount: sheet.totalAssets,
                             code: sheet.currencyCode, emphasised: true)
                }
                Section("Liabilities") {
                    LineRows(lines: sheet.liabilities, code: sheet.currencyCode)
                    TotalRow(label: "Total Liabilities", amount: sheet.totalLiabilities,
                             code: sheet.currencyCode, emphasised: true)
                }
                Section("Equity") {
                    LineRows(lines: sheet.equity, code: sheet.currencyCode)
                    TotalRow(label: "Retained Earnings", amount: sheet.retainedEarnings,
                             code: sheet.currencyCode)
                    TotalRow(label: "Total Equity", amount: sheet.totalEquity,
                             code: sheet.currencyCode, emphasised: true)
                }
            }
        } else {
            ContentUnavailableView("No data", systemImage: "chart.pie")
        }
    }
}

private struct IncomeStatementView: View {
    @Bindable var model: AppModel
    var body: some View {
        let end = Date()
        let start = Calendar.current.date(byAdding: .year, value: -1, to: end) ?? end
        if let statement = model.incomeStatement(from: start, to: end) {
            List {
                Section("Income") {
                    LineRows(lines: statement.income, code: statement.currencyCode)
                    TotalRow(label: "Total Income", amount: statement.totalIncome,
                             code: statement.currencyCode, emphasised: true)
                }
                Section("Expenses") {
                    LineRows(lines: statement.expenses, code: statement.currencyCode)
                    TotalRow(label: "Total Expenses", amount: statement.totalExpenses,
                             code: statement.currencyCode, emphasised: true)
                }
                Section {
                    TotalRow(label: "Net Income", amount: statement.netIncome,
                             code: statement.currencyCode, emphasised: true)
                }
            }
        } else {
            ContentUnavailableView("No data", systemImage: "chart.bar")
        }
    }
}

private struct NetWorthChartView: View {
    @Bindable var model: AppModel
    var body: some View {
        let points = model.netWorthSeries(months: 12)
        if points.contains(where: { $0.netWorth != 0 }) {
            Chart(points) { point in
                LineMark(x: .value("Month", point.date, unit: .month),
                         y: .value("Net Worth", point.netWorth))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Month", point.date, unit: .month),
                         y: .value("Net Worth", point.netWorth))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.3), .clear],
                                                     startPoint: .top, endPoint: .bottom))
            }
            .padding()
        } else {
            ContentUnavailableView("Not enough history", systemImage: "chart.line.uptrend.xyaxis")
        }
    }
}

private struct PortfolioView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let portfolio = model.portfolio() {
            List {
                ForEach(portfolio.holdings) { holding in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(holding.accountName).fontWeight(.medium)
                            Text(holding.symbol).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let value = holding.marketValue {
                                Text(AmountFormat.string(value, code: portfolio.currencyCode))
                                    .monospacedDigit()
                            } else {
                                Text("no price").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Text("\(holding.shares.formatted()) @ \(holding.price.map { AmountFormat.string($0, code: portfolio.currencyCode) } ?? "—")")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let gain = holding.gain {
                                Text(gainText(gain, fraction: holding.gainFraction, code: portfolio.currencyCode))
                                    .font(.caption)
                                    .foregroundStyle(gain < 0 ? .red : .green)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section {
                    TotalRow(label: "Cost basis", amount: portfolio.totalCost, code: portfolio.currencyCode)
                    TotalRow(label: "Market value", amount: portfolio.totalValue, code: portfolio.currencyCode, emphasised: true)
                    HStack {
                        Text("Total gain").fontWeight(.bold)
                        Spacer()
                        Text(AmountFormat.string(portfolio.totalGain, code: portfolio.currencyCode))
                            .monospacedDigit().fontWeight(.bold)
                            .foregroundStyle(portfolio.totalGain < 0 ? .red : .green)
                    }
                }
            }
        } else {
            ContentUnavailableView("No securities", systemImage: "chart.pie",
                                   description: Text("Add a stock or fund account to see your portfolio."))
        }
    }

    private func gainText(_ gain: Decimal, fraction: Double?, code: String) -> String {
        let amount = AmountFormat.string(gain, code: code)
        if let fraction { return "\(amount) (\(fraction.formatted(.percent.precision(.fractionLength(1)))))" }
        return amount
    }
}

private struct CapitalGainsView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let report = model.capitalGains() {
            List {
                Section {
                    Picker("Method", selection: $model.costBasisMethod) {
                        ForEach(CostBasisMethod.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                if report.lines.isEmpty {
                    Text("No realised gains yet.").foregroundStyle(.secondary)
                } else {
                    Section("Realised gains") {
                        ForEach(report.lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(line.symbol).fontWeight(.medium)
                                    termBadge(line.longTerm)
                                    Spacer()
                                    Text(AmountFormat.string(line.gain, code: report.currencyCode))
                                        .monospacedDigit()
                                        .foregroundStyle(line.gain < 0 ? .red : .green)
                                }
                                HStack {
                                    Text("\(line.quantity.formatted()) sold \(line.disposalDate, format: .dateTime.year().month().day())")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("proceeds \(AmountFormat.string(line.proceeds, code: report.currencyCode)) − cost \(AmountFormat.string(line.costBasis, code: report.currencyCode))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    Section {
                        TotalRow(label: "Short-term gain", amount: report.shortTermGain, code: report.currencyCode)
                        TotalRow(label: "Long-term gain", amount: report.longTermGain, code: report.currencyCode)
                        if report.otherGain != 0 {
                            TotalRow(label: "Other", amount: report.otherGain, code: report.currencyCode)
                        }
                        HStack {
                            Text("Total realised").fontWeight(.bold)
                            Spacer()
                            Text(AmountFormat.string(report.totalGain, code: report.currencyCode))
                                .monospacedDigit().fontWeight(.bold)
                                .foregroundStyle(report.totalGain < 0 ? .red : .green)
                        }
                    }
                }
                if !report.openLots.isEmpty {
                    Section("Open lots") {
                        ForEach(report.openLots) { lot in
                            HStack {
                                Text(lot.symbol).fontWeight(.medium)
                                if let date = lot.acquisitionDate {
                                    Text(date, format: .dateTime.year().month().day())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(lot.quantity.formatted()) · \(AmountFormat.string(lot.costBasis, code: report.currencyCode))")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No securities", systemImage: "chart.line.uptrend.xyaxis",
                                   description: Text("Record buys and sells in a stock or fund account to see capital gains."))
        }
    }

    @ViewBuilder
    private func termBadge(_ longTerm: Bool?) -> some View {
        switch longTerm {
        case .some(true):
            Text("LT").font(.caption2).padding(.horizontal, 4).background(.green.opacity(0.2)).clipShape(Capsule())
        case .some(false):
            Text("ST").font(.caption2).padding(.horizontal, 4).background(.orange.opacity(0.2)).clipShape(Capsule())
        case .none:
            EmptyView()
        }
    }
}

private struct CashFlowView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let accountID = model.defaultForecastAccountID {
            let points = model.cashFlowForecast(accountID: accountID)
            let events = points.filter { $0.change != 0 }
            if events.isEmpty {
                ContentUnavailableView("No upcoming activity", systemImage: "calendar",
                                       description: Text("Add scheduled transactions to forecast cash flow."))
            } else {
                VStack(spacing: 0) {
                    Chart(points) { point in
                        LineMark(x: .value("Date", point.date), y: .value("Balance", point.balance))
                            .interpolationMethod(.stepEnd)
                        RuleMark(y: .value("Zero", 0))
                            .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4]))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 180)
                    .padding()
                    Divider()
                    List(events) { event in
                        HStack {
                            Text(event.date, format: .dateTime.year().month().day())
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            Text(event.label)
                            Spacer()
                            Text(AmountFormat.string(event.change, code: model.reportCurrency.mnemonic))
                                .monospacedDigit()
                                .foregroundStyle(event.change < 0 ? .red : .green)
                            Text(AmountFormat.string(event.balance, code: model.reportCurrency.mnemonic))
                                .monospacedDigit()
                                .frame(width: 96, alignment: .trailing)
                                .foregroundStyle(event.balance < 0 ? .red : .primary)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No account to forecast", systemImage: "banknote",
                                   description: Text("Create an asset account first."))
        }
    }
}
