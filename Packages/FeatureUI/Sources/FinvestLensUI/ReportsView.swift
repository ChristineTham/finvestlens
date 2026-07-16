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
import FinvestLensIntelligence

/// A tabbed reports view: Balance Sheet, Income Statement, and a Net-Worth chart.
/// Wraps the reports workspace for presentation in its own window (HIG:
/// sheets are for brief, focused tasks — an analytics workspace gets a
/// window so it doesn't block the register).
public struct ReportsWindow: View {
    @Bindable var model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        if model.isOpen {
            ReportsView(model: model)
        } else {
            ContentUnavailableView("No book open", systemImage: "chart.pie",
                                   description: Text("Open a book to see its reports."))
                .frame(minWidth: 520, minHeight: 440)
        }
    }
}

struct ReportsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ReportKind = .balanceSheet
    @State private var exporting = false
    @State private var pdfDocument: PDFReportDocument?

    enum ReportKind: String, CaseIterable, Identifiable {
        case balanceSheet = "Balance Sheet"
        case incomeStatement = "Income Statement"
        case equityStatement = "Equity Statement"
        case trialBalance = "Trial Balance"
        case accountSummary = "Account Summary"
        case incomeExpense = "Income & Expense"
        case cashFlow = "Cash Flow"
        case transactions = "Transactions"
        case reconcile = "Reconciliation"
        case netWorth = "Net Worth"
        /// The balance projection that used to be called Cash Flow — renamed
        /// because GnuCash's Cash Flow is the report above: an accounting of a
        /// period that happened, not a projection of one that hasn't.
        case forecast = "Forecast"
        case portfolio = "Portfolio"
        case investmentLots = "Investment Lots"
        case priceScatter = "Price Scatter"
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
                case .equityStatement: EquityStatementView(model: model)
                case .trialBalance: TrialBalanceView(model: model)
                case .accountSummary: AccountSummaryView(model: model)
                case .incomeExpense: IncomeExpenseView(model: model)
                case .cashFlow: CashFlowReportView(model: model)
                case .transactions: TransactionReportView(model: model)
                case .reconcile: ReconcileReportView(model: model)
                case .netWorth: NetWorthChartView(model: model)
                case .forecast: CashFlowView(model: model)
                case .portfolio: PortfolioView(model: model)
                case .investmentLots: InvestmentLotsView(model: model)
                case .priceScatter: PriceScatterView(model: model)
                case .capitalGains: CapitalGainsView(model: model)
                }
            }
            .navigationTitle("Reports")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if printableStatement != nil {
                    ToolbarItem {
                        Button("PDF", systemImage: "arrow.up.doc") { exportPDF() }
                    }
                }
            }
            .fileExporter(isPresented: $exporting, document: pdfDocument,
                          contentType: .pdf, defaultFilename: selection.rawValue) { _ in }
        }
        .frame(minWidth: 520, minHeight: 440)
    }

    /// A printable statement for the current report, or `nil` for reports that
    /// are chart/table-only.
    private var printableStatement: PrintableStatement? {
        let code = model.reportCurrency.mnemonic
        switch selection {
        case .balanceSheet:
            guard let sheet = model.balanceSheet() else { return nil }
            return PrintableStatement(
                title: "Balance Sheet",
                subtitle: "As of \(sheet.asOf.formatted(.dateTime.year().month().day())) · \(code)",
                code: code,
                sections: [
                    PrintableSection(heading: "Assets", rows:
                        sheet.assets.map { PrintableRow(label: $0.name, amount: $0.amount) }
                        + [PrintableRow(label: "Total Assets", amount: sheet.totalAssets, bold: true)]),
                    PrintableSection(heading: "Liabilities", rows:
                        sheet.liabilities.map { PrintableRow(label: $0.name, amount: $0.amount) }
                        + [PrintableRow(label: "Total Liabilities", amount: sheet.totalLiabilities, bold: true)]),
                    PrintableSection(heading: "Equity", rows:
                        sheet.equity.map { PrintableRow(label: $0.name, amount: $0.amount) }
                        + [PrintableRow(label: "Retained Earnings", amount: sheet.retainedEarnings),
                           PrintableRow(label: "Total Equity", amount: sheet.totalEquity, bold: true)]),
                ])
        case .incomeStatement:
            let cal = Calendar(identifier: .gregorian)
            let start = cal.date(byAdding: .month, value: -12, to: Date()) ?? Date()
            guard let statement = model.incomeStatement(from: start, to: Date()) else { return nil }
            return PrintableStatement(
                title: "Income Statement",
                subtitle: "\(start.formatted(.dateTime.year().month())) – \(Date().formatted(.dateTime.year().month())) · \(code)",
                code: code,
                sections: [
                    PrintableSection(heading: "Income", rows:
                        statement.income.map { PrintableRow(label: $0.name, amount: $0.amount) }
                        + [PrintableRow(label: "Total Income", amount: statement.totalIncome, bold: true)]),
                    PrintableSection(heading: "Expenses", rows:
                        statement.expenses.map { PrintableRow(label: $0.name, amount: $0.amount) }
                        + [PrintableRow(label: "Total Expenses", amount: statement.totalExpenses, bold: true)]),
                    PrintableSection(heading: "Summary", rows:
                        [PrintableRow(label: "Net Income", amount: statement.netIncome, bold: true)]),
                ])
        default:
            return nil
        }
    }

    private func exportPDF() {
        guard let statement = printableStatement, let data = ReportExport.pdf(statement) else { return }
        pdfDocument = PDFReportDocument(data: data)
        exporting = true
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
                // The full path, not the leaf: a real book has five accounts
                // called "Franked", one per holding, and a statement that
                // cannot tell them apart is not a statement.
                Text(line.fullName).foregroundStyle(.secondary)
                Spacer()
                Text(AmountFormat.string(line.amount, code: code)).monospacedDigit()
            }
        }
    }
}

private struct BalanceSheetView: View {
    @Bindable var model: AppModel
    @State private var asOf = Date()
    var body: some View {
        VStack(spacing: 0) {
            Form {
                DatePicker("As of", selection: $asOf, displayedComponents: .date)
            }
            .frame(maxHeight: 70)
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let sheet = model.balanceSheet(asOf: asOf) {
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
    /// Defaults to the calendar year to date — the period the question "how is
    /// the year going" is about, and one whose answer can be checked against a
    /// year-end figure.
    @State private var from = Calendar.current.date(
        from: Calendar.current.dateComponents([.year], from: Date())) ?? Date()
    @State private var to = Date()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
            }
            .frame(maxHeight: 100)
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let statement = model.incomeStatement(from: from, to: to) {
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

/// GnuCash's Equity Statement: the bridge between two balance sheets.
private struct EquityStatementView: View {
    @Bindable var model: AppModel
    @State private var from = Calendar.current.date(
        from: Calendar.current.dateComponents([.year], from: Date())) ?? Date()
    @State private var to = Date()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
            }
            .frame(maxHeight: 100)
            Divider()
            if let statement = model.equityStatement(from: from, to: to) {
                List {
                    Section("Capital") {
                        TotalRow(label: "Opening capital", amount: statement.openingCapital,
                                 code: statement.currencyCode)
                        TotalRow(label: "Net income", amount: statement.netIncome,
                                 code: statement.currencyCode)
                        TotalRow(label: "Contributions", amount: statement.contributions,
                                 code: statement.currencyCode)
                        TotalRow(label: "Withdrawals", amount: -statement.withdrawals,
                                 code: statement.currencyCode)
                        TotalRow(label: "Unrealised gains and FX",
                                 amount: statement.unrealisedChange,
                                 code: statement.currencyCode)
                    }
                    Section {
                        TotalRow(label: "Closing capital", amount: statement.closingCapital,
                                 code: statement.currencyCode, emphasised: true)
                    } footer: {
                        if !statement.isConsistent {
                            Text("These figures do not add up. Please report this.")
                                .foregroundStyle(.red)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No data", systemImage: "chart.bar")
            }
        }
    }
}

/// GnuCash's Trial Balance: every balance in a debit or credit column, and the
/// columns must agree — with the unrealised adjustment shown, not hidden.
private struct TrialBalanceView: View {
    @Bindable var model: AppModel
    @State private var asOf = Date()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                DatePicker("As of", selection: $asOf, displayedComponents: .date)
            }
            .frame(maxHeight: 70)
            Divider()
            if let report = model.trialBalance(asOf: asOf) {
                Table(report.rows) {
                    TableColumn("Account") { row in Text(row.fullName) }
                    TableColumn("Debit") { row in
                        if let debit = row.debit {
                            Text(AmountFormat.string(debit, code: report.currencyCode))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    TableColumn("Credit") { row in
                        if let credit = row.credit {
                            Text(AmountFormat.string(credit, code: report.currencyCode))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                Divider()
                VStack(spacing: 4) {
                    if report.unrealisedAdjustment != 0 {
                        HStack {
                            Text("Unrealised gains (adjustment)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(AmountFormat.string(report.unrealisedAdjustment,
                                                     code: report.currencyCode))
                                .monospacedDigit()
                        }
                    }
                    HStack {
                        Text("Totals").fontWeight(.semibold)
                        Spacer()
                        Text("Debits \(AmountFormat.string(report.totalDebits, code: report.currencyCode))"
                             + "   Credits \(AmountFormat.string(report.totalCredits, code: report.currencyCode))")
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(report.isBalanced ? .primary : Color.red)
                    }
                }
                .scaledFont(.body)
                .padding(10)
            } else {
                ContentUnavailableView("No data", systemImage: "chart.bar")
            }
        }
    }
}

/// GnuCash's Account Summary: the whole chart of accounts, cut at a depth.
private struct AccountSummaryView: View {
    @Bindable var model: AppModel
    @State private var asOf = Date()
    @State private var depth = 2

    var body: some View {
        VStack(spacing: 0) {
            Form {
                DatePicker("As of", selection: $asOf, displayedComponents: .date)
                Stepper("Depth: \(depth)", value: $depth, in: 1...6)
            }
            .frame(maxHeight: 100)
            Divider()
            if let report = model.accountSummary(asOf: asOf, depthLimit: depth) {
                List {
                    ForEach(report.sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                HStack {
                                    Text(row.name)
                                        .padding(.leading, CGFloat(row.depth - 1) * 16)
                                        .foregroundStyle(row.depth == 1 ? .primary : .secondary)
                                    Spacer()
                                    Text(AmountFormat.string(row.balance, code: report.currencyCode))
                                        .monospacedDigit()
                                }
                            }
                            TotalRow(label: "Total \(section.title)", amount: section.total,
                                     code: report.currencyCode, emphasised: true)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No data", systemImage: "list.bullet.indent")
            }
        }
    }
}

/// GnuCash's Cash Flow: where the period's money came from and went.
private struct CashFlowReportView: View {
    @Bindable var model: AppModel
    @State private var accountIDs: Set<GncGUID> = []
    @State private var pickerShown = false
    @State private var from = Calendar.current.date(
        from: Calendar.current.dateComponents([.year], from: Date())) ?? Date()
    @State private var to = Date()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    Text("Accounts")
                    Spacer()
                    Button(label) { pickerShown = true }
                        .popover(isPresented: $pickerShown) {
                            AccountMatchPicker(tree: model.accountTree,
                                               selection: $accountIDs)
                        }
                }
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
            }
            .frame(maxHeight: 130)
            Divider()
            if let report = model.cashFlow(accountIDs: accountIDs, from: from, to: to) {
                List {
                    Section("Money in, from") {
                        LineRows(lines: report.inflows, code: report.currencyCode)
                        TotalRow(label: "Total in", amount: report.totalIn,
                                 code: report.currencyCode, emphasised: true)
                    }
                    Section("Money out, to") {
                        LineRows(lines: report.outflows, code: report.currencyCode)
                        TotalRow(label: "Total out", amount: report.totalOut,
                                 code: report.currencyCode, emphasised: true)
                    }
                    Section {
                        TotalRow(label: "Net change", amount: report.netChange,
                                 code: report.currencyCode, emphasised: true)
                    }
                }
            } else {
                ContentUnavailableView("Choose accounts", systemImage: "arrow.left.arrow.right",
                                       description: Text("Pick the accounts to follow the money "
                                                         + "through — usually your bank accounts."))
            }
        }
    }

    private var label: String {
        switch accountIDs.count {
        case 0: "Choose…"
        case 1: model.accountName(accountIDs.first!) ?? "1 account"
        default: "\(accountIDs.count) accounts"
        }
    }
}

/// GnuCash's Income & Expense charts: where does it all go, as a picture.
private struct IncomeExpenseView: View {
    @Bindable var model: AppModel
    @State private var from = Calendar.current.date(
        from: Calendar.current.dateComponents([.year], from: Date())) ?? Date()
    @State private var to = Date()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
            }
            .frame(maxHeight: 100)
            Divider()
            if let breakdown = model.categoryBreakdown(from: from, to: to),
               !breakdown.months.isEmpty {
                List {
                    Section("By month") {
                        Chart(breakdown.months) { month in
                            BarMark(x: .value("Month", month.month, unit: .month),
                                    y: .value("Income", month.income))
                                .foregroundStyle(by: .value("Kind", "Income"))
                                .position(by: .value("Kind", "Income"))
                            BarMark(x: .value("Month", month.month, unit: .month),
                                    y: .value("Expenses", month.expenses))
                                .foregroundStyle(by: .value("Kind", "Expenses"))
                                .position(by: .value("Kind", "Expenses"))
                        }
                        .chartForegroundStyleScale(["Income": Color.accentColor,
                                                    "Expenses": Color.red.opacity(0.75)])
                        .frame(height: 220)
                        .padding(.vertical, 6)
                    }
                    Section("Spending by category") {
                        LineRows(lines: breakdown.expenseSlices, code: breakdown.currencyCode)
                        TotalRow(label: "Total Expenses", amount: breakdown.totalExpenses,
                                 code: breakdown.currencyCode, emphasised: true)
                    }
                    Section("Income by category") {
                        LineRows(lines: breakdown.incomeSlices, code: breakdown.currencyCode)
                        TotalRow(label: "Total Income", amount: breakdown.totalIncome,
                                 code: breakdown.currencyCode, emphasised: true)
                    }
                }
            } else {
                ContentUnavailableView("No activity", systemImage: "chart.pie",
                                       description: Text("No income or spending in this period."))
            }
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
            .accessibilityLabel("Net worth trend")
        } else {
            ContentUnavailableView("Not enough history", systemImage: "chart.line.uptrend.xyaxis")
        }
    }
}

private struct PortfolioView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let portfolio = model.advancedPortfolio() {
            List {
                if portfolio.totalValue != 0 {
                    Section("Allocation") {
                        AllocationChart(portfolio: portfolio)
                    }
                }
                Section("Holdings") {
                    ForEach(portfolio.holdings) { holding in
                        HoldingRow(holding: holding, code: portfolio.currencyCode)
                    }
                }
                Section {
                    TotalRow(label: "Cost basis", amount: portfolio.totalCost, code: portfolio.currencyCode)
                    TotalRow(label: "Market value", amount: portfolio.totalValue, code: portfolio.currencyCode, emphasised: true)
                    signedTotal("Unrealized gain", portfolio.totalUnrealized, portfolio.currencyCode)
                    signedTotal("Realized gain", portfolio.totalRealized, portfolio.currencyCode)
                    if let ror = portfolio.totalReturnFraction {
                        HStack {
                            Text("Total return").fontWeight(.bold)
                            Spacer()
                            Text(ror.formatted(.percent.precision(.fractionLength(1))))
                                .monospacedDigit().fontWeight(.bold)
                                .foregroundStyle(ror < 0 ? .red : (ror > 0 ? .green : .primary))
                        }
                    }
                }
                PriceHistorySection(model: model)
            }
        } else {
            ContentUnavailableView("No securities", systemImage: "chart.pie",
                                   description: Text("Add a stock or fund account to see your portfolio."))
        }
    }

    private func signedTotal(_ label: String, _ amount: Decimal, _ code: String) -> some View {
        HStack {
            Text(label).fontWeight(.bold)
            Spacer()
            Text(AmountFormat.string(amount, code: code))
                .monospacedDigit().fontWeight(.bold)
                .foregroundStyle(amount < 0 ? .red : (amount > 0 ? .green : .primary))
        }
    }
}

private struct HoldingRow: View {
    let holding: AdvancedHolding
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(holding.symbol).fontWeight(.medium)
                if let allocation = holding.allocation {
                    Text(allocation.formatted(.percent.precision(.fractionLength(0))))
                        .scaledFont(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).background(.secondary.opacity(0.15)).clipShape(Capsule())
                }
                Spacer()
                if let value = holding.marketValue {
                    Text(AmountFormat.string(value, code: code)).monospacedDigit()
                } else {
                    Text("no price").scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(holding.shares.formatted()) @ \(holding.averageCost.map { AmountFormat.string($0, code: code) } ?? "—") avg")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                Spacer()
                if let gain = holding.unrealizedGain {
                    Text(gainText(gain, fraction: holding.unrealizedFraction, code: code))
                        .scaledFont(.caption).foregroundStyle(gain < 0 ? .red : .green)
                }
            }
            if holding.realizedGain != 0 {
                HStack {
                    Text("Realized").scaledFont(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(AmountFormat.string(holding.realizedGain, code: code))
                        .scaledFont(.caption2).monospacedDigit()
                        .foregroundStyle(holding.realizedGain < 0 ? .red : .green)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func gainText(_ gain: Decimal, fraction: Double?, code: String) -> String {
        let amount = AmountFormat.string(gain, code: code)
        if let fraction { return "\(amount) (\(fraction.formatted(.percent.precision(.fractionLength(1)))))" }
        return amount
    }
}

private struct AllocationChart: View {
    let portfolio: AdvancedPortfolio

    private var slices: [(symbol: String, value: Double)] {
        portfolio.holdings.compactMap { h in
            guard let v = h.marketValue, v != 0 else { return nil }
            return (h.symbol, NSDecimalNumber(decimal: v).doubleValue)
        }
    }

    var body: some View {
        Chart(slices, id: \.symbol) { slice in
            SectorMark(angle: .value("Value", slice.value), innerRadius: .ratio(0.6), angularInset: 1.5)
                .foregroundStyle(by: .value("Security", slice.symbol))
                .cornerRadius(3)
        }
        .frame(height: 180)
        .padding(.vertical, 4)
        .accessibilityLabel("Portfolio allocation by security")
    }
}

private struct PriceHistorySection: View {
    @Bindable var model: AppModel
    @State private var selected: String = ""

    private var securities: [Commodity] { model.securitiesWithPriceHistory }

    /// Default to a security that actually has a chartable trend (≥2 prices),
    /// falling back to the first one; never leaves the picker blank.
    private var defaultCode: String {
        securities.first { model.priceHistory(for: $0).count >= 2 }?.mnemonic
            ?? securities.first?.mnemonic ?? ""
    }
    private var chosen: Commodity? {
        securities.first { $0.mnemonic == selected }
            ?? securities.first { $0.mnemonic == defaultCode }
    }

    var body: some View {
        if !securities.isEmpty, let commodity = chosen {
            Section("Price History") {
                if securities.count > 1 {
                    Picker("Security", selection: Binding(
                        get: { chosen?.mnemonic ?? defaultCode },
                        set: { selected = $0 })) {
                        ForEach(securities, id: \.mnemonic) { Text($0.mnemonic).tag($0.mnemonic) }
                    }
                    .pickerStyle(.menu)
                }
                let points = model.priceHistory(for: commodity)
                if points.count < 2 {
                    Text("Add more prices to chart a trend.").scaledFont(.caption).foregroundStyle(.secondary)
                } else {
                    Chart(points) { point in
                        LineMark(x: .value("Date", point.date),
                                 y: .value("Price", NSDecimalNumber(decimal: point.value).doubleValue))
                        PointMark(x: .value("Date", point.date),
                                  y: .value("Price", NSDecimalNumber(decimal: point.value).doubleValue))
                            .symbolSize(20)
                    }
                    .frame(height: 160)
                    .padding(.vertical, 4)
                    .accessibilityLabel("Price history for \(commodity.mnemonic)")
                }
            }
        }
    }
}

/// GnuCash's Reconciliation Report: of what is in this account, how much has the
/// bank agreed to? (`FR-RPT-05`)
private struct ReconcileReportView: View {
    @Bindable var model: AppModel
    @State private var accountID: GncGUID?
    @State private var asOf = Date()
    @Environment(\.appFontScale) private var appFontScale
    private var dateWidth: CGFloat { 90 * appFontScale }

    /// Reconciling is a bank-statement idea, so the accounts offered are the
    /// ones a statement arrives for.
    private var accounts: [AccountNode] {
        model.postableAccounts.filter { ["Bank", "Cash", "Credit", "Asset", "Liability"]
            .contains($0.typeName) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Account", selection: $accountID) {
                    Text("—").tag(GncGUID?.none)
                    ForEach(accounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                }
                DatePicker("As of", selection: $asOf, displayedComponents: .date)
            }
            .frame(maxHeight: 110)
            Divider()
            if let id = accountID, let report = model.reconcileReport(accountID: id, asOf: asOf) {
                content(report)
            } else {
                ContentUnavailableView("Choose an account", systemImage: "checkmark.circle",
                                       description: Text("See what has been reconciled, what is "
                                                         + "cleared, and what is neither."))
            }
        }
    }

    private func content(_ report: ReconcileReport) -> some View {
        List {
            section("Funds In", report.fundsIn, report.totalIn, report)
            section("Funds Out", report.fundsOut, report.totalOut, report)
            Section("Reconciled") {
                total("Reconciled balance", report.reconciledBalance, report, emphasised: true)
            }
            section("Cleared — on a statement, not yet reconciled",
                    report.cleared, report.clearedTotal, report)
            Section {
                total("Cleared balance", report.clearedBalance, report)
            }
            section("Outstanding — not on a statement", report.outstanding,
                    report.outstandingTotal, report)
            Section {
                total("Ending balance", report.endingBalance, report, emphasised: true)
            } footer: {
                // The report's whole claim, said out loud. If it ever fails the
                // figures are lying, and saying nothing would be worse.
                if !report.isConsistent {
                    Text("These figures do not add up. Please report this.")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [ReconcileReportRow],
                         _ sum: Decimal, _ report: ReconcileReport) -> some View {
        Section(title) {
            if rows.isEmpty {
                Text("Nothing.").scaledFont(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text(row.date, format: .dateTime.year().month().day())
                            .foregroundStyle(.secondary)
                            .frame(width: dateWidth, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(row.description)
                            if !row.memo.isEmpty {
                                Text(row.memo).scaledFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(AmountFormat.string(row.amount, code: report.currencyCode))
                            .monospacedDigit()
                            .foregroundStyle(row.amount < 0 ? .red : .primary)
                    }
                }
                total("Total", sum, report)
            }
        }
    }

    private func total(_ label: String, _ amount: Decimal, _ report: ReconcileReport,
                       emphasised: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(emphasised ? .semibold : .regular)
            Spacer()
            Text(AmountFormat.string(amount, code: report.currencyCode))
                .monospacedDigit()
                .fontWeight(emphasised ? .semibold : .regular)
        }
    }
}

private struct TransactionReportView: View {
    @Bindable var model: AppModel
    @State private var accountID: GncGUID?
    @State private var from = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var to = Date()
    @Environment(\.appFontScale) private var appFontScale
    private var dateWidth: CGFloat { 90 * appFontScale }
    private var amountWidth: CGFloat { 90 * appFontScale }

    private var accounts: [AccountNode] { model.postableAccounts }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Account", selection: $accountID) {
                    Text("—").tag(GncGUID?.none)
                    ForEach(accounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                }
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
            }
            .frame(maxHeight: 140)
            Divider()
            if let id = accountID, let report = model.transactionReport(accountID: id, from: from, to: to) {
                if report.rows.isEmpty {
                    ContentUnavailableView("No postings", systemImage: "list.bullet.rectangle",
                                           description: Text("No transactions in this period."))
                } else {
                    List {
                        ForEach(report.rows) { row in
                            HStack {
                                Text(row.date, format: .dateTime.year().month().day())
                                    .foregroundStyle(.secondary).frame(width: dateWidth, alignment: .leading)
                                VStack(alignment: .leading) {
                                    Text(row.description)
                                    Text(row.transfer).scaledFont(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(AmountFormat.string(row.amount, code: report.currencyCode))
                                    .monospacedDigit().foregroundStyle(row.amount < 0 ? .red : .primary)
                                Text(AmountFormat.string(row.balance, code: report.currencyCode))
                                    .monospacedDigit().frame(width: amountWidth, alignment: .trailing)
                            }
                        }
                        Section {
                            TotalRow(label: "Opening", amount: report.opening, code: report.currencyCode)
                            TotalRow(label: "Net change", amount: report.total, code: report.currencyCode)
                            TotalRow(label: "Closing", amount: report.closing, code: report.currencyCode, emphasised: true)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Choose an account", systemImage: "list.bullet.rectangle",
                                       description: Text("Pick an account to list its postings."))
            }
        }
    }
}

private struct InvestmentLotsView: View {
    @Bindable var model: AppModel

    var body: some View {
        let lots = model.investmentLots()
        if lots.isEmpty {
            ContentUnavailableView("No open lots", systemImage: "square.stack.3d.up",
                                   description: Text("Buy a security to see its tax lots."))
        } else {
            List {
                Section {
                    Picker("Method", selection: $model.costBasisMethod) {
                        ForEach(CostBasisMethod.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Open Lots") {
                    ForEach(lots) { lot in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(lot.symbol).fontWeight(.medium)
                                if let date = lot.acquisitionDate {
                                    Text(date, format: .dateTime.year().month().day())
                                        .scaledFont(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(lot.marketValue.map { AmountFormat.string($0, code: model.reportCurrency.mnemonic) } ?? "no price")
                                    .monospacedDigit()
                            }
                            HStack {
                                Text("\(lot.quantity.formatted()) · cost \(AmountFormat.string(lot.costBasis, code: model.reportCurrency.mnemonic))")
                                    .scaledFont(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if let gain = lot.unrealizedGain {
                                    Text(AmountFormat.string(gain, code: model.reportCurrency.mnemonic))
                                        .scaledFont(.caption).monospacedDigit()
                                        .foregroundStyle(gain < 0 ? .red : .green)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

private struct PriceScatterView: View {
    @Bindable var model: AppModel

    private struct Point: Identifiable {
        let id = UUID()
        let symbol: String
        let date: Date
        let price: Double
    }

    private var points: [Point] {
        model.securitiesWithPriceHistory.flatMap { commodity in
            model.priceHistory(for: commodity).map {
                Point(symbol: commodity.mnemonic, date: $0.date,
                      price: NSDecimalNumber(decimal: $0.value).doubleValue)
            }
        }
    }

    var body: some View {
        let data = points
        if data.isEmpty {
            ContentUnavailableView("No prices", systemImage: "chart.dots.scatter",
                                   description: Text("Record security prices to plot them over time."))
        } else {
            VStack(alignment: .leading) {
                Chart(data) { point in
                    PointMark(x: .value("Date", point.date),
                              y: .value("Price", point.price))
                        .foregroundStyle(by: .value("Security", point.symbol))
                }
                .frame(minHeight: 260)
                .padding()
                .accessibilityLabel("Price scatter of all securities over time")
            }
        }
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
                                        .scaledFont(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("proceeds \(AmountFormat.string(line.proceeds, code: report.currencyCode)) − cost \(AmountFormat.string(line.costBasis, code: report.currencyCode))")
                                        .scaledFont(.caption).foregroundStyle(.secondary)
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
                                        .scaledFont(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(lot.quantity.formatted()) · \(AmountFormat.string(lot.costBasis, code: report.currencyCode))")
                                    .scaledFont(.caption).monospacedDigit().foregroundStyle(.secondary)
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
            Text("LT").scaledFont(.caption2).padding(.horizontal, 4).background(.green.opacity(0.2)).clipShape(Capsule())
        case .some(false):
            Text("ST").scaledFont(.caption2).padding(.horizontal, 4).background(.orange.opacity(0.2)).clipShape(Capsule())
        case .none:
            EmptyView()
        }
    }
}

private struct CashFlowView: View {
    @Bindable var model: AppModel
    @State private var showAddWhatIf = false
    @State private var wiDate = Date()
    @State private var wiAmount = ""
    @State private var wiLabel = ""
    @State private var insights: ForecastInsights?
    @State private var generatingOutlook = false
    @State private var outlookError: String?
    @Environment(\.appFontScale) private var appFontScale
    private var dateWidth: CGFloat { 96 * appFontScale }
    private var balanceWidth: CGFloat { 96 * appFontScale }

    var body: some View {
        if let accountID = model.defaultForecastAccountID {
            let points = model.cashFlowForecast(accountID: accountID)
            let events = points.filter { $0.change != 0 }
            VStack(spacing: 0) {
                whatIfBar
                Divider()
                if events.isEmpty {
                    ContentUnavailableView("No upcoming activity", systemImage: "calendar",
                                           description: Text("Add scheduled transactions or a what-if event to forecast cash flow."))
                } else {
                    Chart {
                        ForEach(points) { point in
                            LineMark(x: .value("Date", point.date), y: .value("Balance", point.balance))
                                .interpolationMethod(.stepEnd)
                        }
                        ForEach(points.filter(\.isWhatIf)) { point in
                            PointMark(x: .value("Date", point.date), y: .value("Balance", point.balance))
                                .foregroundStyle(.orange)
                        }
                        RuleMark(y: .value("Zero", 0))
                            .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4]))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 170)
                    .padding()
                    .accessibilityLabel("Projected cash-flow balance")
                    Divider()
                    if model.isIntelligenceAvailable {
                        outlookBar
                        Divider()
                    }
                    List(events) { event in
                        HStack {
                            Text(event.date, format: .dateTime.year().month().day())
                                .foregroundStyle(.secondary)
                                .frame(width: dateWidth, alignment: .leading)
                            Text(event.label)
                            if event.isWhatIf {
                                Text("what-if").scaledFont(.caption2)
                                    .padding(.horizontal, 4).background(.orange.opacity(0.2)).clipShape(Capsule())
                            }
                            Spacer()
                            Text(AmountFormat.string(event.change, code: model.reportCurrency.mnemonic))
                                .monospacedDigit()
                                .foregroundStyle(event.change < 0 ? .red : .green)
                            Text(AmountFormat.string(event.balance, code: model.reportCurrency.mnemonic))
                                .monospacedDigit()
                                .frame(width: balanceWidth, alignment: .trailing)
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

    private var whatIfBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What-if scenario").scaledFont(.subheadline).fontWeight(.medium)
                Spacer()
                Button(showAddWhatIf ? "Close" : "Add event", systemImage: "plus") {
                    showAddWhatIf.toggle()
                }
                .scaledFont(.caption)
            }
            if showAddWhatIf {
                HStack {
                    DatePicker("", selection: $wiDate, displayedComponents: .date).labelsHidden()
                    TextField("Amount (+in / −out)", text: $wiAmount)
                        .frame(width: 130).multilineTextAlignment(.trailing)
                    TextField("Label", text: $wiLabel).frame(width: 120)
                    Button("Add") { addWhatIf() }.disabled(Decimal(string: wiAmount) == nil)
                }
                .scaledFont(.caption)
            }
            ForEach(model.whatIfEvents) { event in
                HStack(spacing: 4) {
                    Button(role: .destructive) { model.removeWhatIfEvent(event.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Remove what-if event \(event.label)")
                    Text("\(event.label): \(AmountFormat.string(event.amount, code: model.reportCurrency.mnemonic)) on \(event.date, format: .dateTime.year().month().day())")
                        .scaledFont(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func addWhatIf() {
        guard let amount = Decimal(string: wiAmount) else { return }
        model.addWhatIfEvent(date: wiDate, amount: amount, label: wiLabel)
        wiAmount = ""; wiLabel = ""; showAddWhatIf = false
    }

    /// Plain-language outlook on the forecast, written by the on-device
    /// model from the computed numbers (`FR-AI-06`).
    private var outlookBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Outlook", systemImage: "sparkles")
                    .scaledFont(.subheadline).fontWeight(.medium)
                Spacer()
                Button(generatingOutlook ? "Generating…" : (insights == nil ? "Generate" : "Refresh")) {
                    generateOutlook()
                }
                .scaledFont(.caption)
                .disabled(generatingOutlook)
            }
            if let insights {
                Text(insights.headline).scaledFont(.callout).fontWeight(.medium)
                ForEach(insights.insights, id: \.self) { insight in
                    Text("•  \(insight)").scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            if let outlookError {
                Text(outlookError).scaledFont(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func generateOutlook() {
        generatingOutlook = true
        outlookError = nil
        Task {
            defer { generatingOutlook = false }
            do {
                insights = try await model.forecastInsights()
            } catch {
                outlookError = error.localizedDescription
            }
        }
    }
}
