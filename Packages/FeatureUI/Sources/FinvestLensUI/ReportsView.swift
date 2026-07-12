//
//  ReportsView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
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
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch selection {
                case .balanceSheet: BalanceSheetView(model: model)
                case .incomeStatement: IncomeStatementView(model: model)
                case .netWorth: NetWorthChartView(model: model)
                }
            }
            .navigationTitle("Reports")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Report", selection: $selection) {
                        ForEach(ReportKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
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
