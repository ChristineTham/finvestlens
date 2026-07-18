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
            NavigationStack { ReportsHome(model: model) }
        } else {
            ContentUnavailableView("No book open", systemImage: "chart.pie",
                                   description: Text("Open a book to see its reports."))
                .frame(minWidth: 520, minHeight: 440)
        }
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

struct PortfolioView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
        if let portfolio = model.advancedPortfolio() {
            List {
                Section {
                    Picker("Method", selection: $model.costBasisMethod) {
                        ForEach(CostBasisMethod.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Fees", selection: $model.feeTreatment) {
                        ForEach(FeeTreatment.allCases) { Text($0.displayName).tag($0) }
                    }
                }
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
        .reportPDFToolbar(title: "Portfolio") { model.portfolioDocument() }
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
            HStack {
                Text("In \(AmountFormat.string(holding.moneyIn, code: code)) · Out \(AmountFormat.string(holding.moneyOut, code: code))"
                     + (holding.income != 0 ? " · Income \(AmountFormat.string(holding.income, code: code))" : ""))
                    .scaledFont(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let roi = holding.returnFraction {
                    Text("ROI \(roi.formatted(.percent.precision(.fractionLength(1))))")
                        .scaledFont(.caption2).monospacedDigit()
                        .foregroundStyle(roi < 0 ? .red : .green)
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
struct ReconcileReportView: View {
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
        .reportPDFToolbar(title: "Reconciliation") {
            accountID.flatMap { model.reconcileDocument(accountID: $0, asOf: asOf) }
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

struct TransactionReportView: View {
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
        .reportPDFToolbar(title: "Transactions") {
            accountID.flatMap { model.transactionsDocument(accountID: $0, from: from, to: to) }
        }
    }
}

struct InvestmentLotsView: View {
    @Bindable var model: AppModel

    var body: some View {
        let lots = model.investmentLots()
        Group {
        if lots.isEmpty {
            ContentUnavailableView("No open lots", systemImage: "square.stack.3d.up",
                                   description: Text("Buy a security to see its tax lots."))
        } else {
            List {
                Section {
                    Picker("Method", selection: $model.costBasisMethod) {
                        ForEach(CostBasisMethod.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Fees", selection: $model.feeTreatment) {
                        ForEach(FeeTreatment.allCases) { Text($0.displayName).tag($0) }
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
        .reportPDFToolbar(title: "Investment Lots") { model.investmentLotsDocument() }
    }
}

struct PriceScatterView: View {
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
        Group {
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
        .reportPDFToolbar(title: "Price History") { model.priceHistoryDocument() }
    }
}

struct CapitalGainsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
        if let report = model.capitalGains() {
            List {
                Section {
                    Picker("Method", selection: $model.costBasisMethod) {
                        ForEach(CostBasisMethod.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Fees", selection: $model.feeTreatment) {
                        ForEach(FeeTreatment.allCases) { Text($0.displayName).tag($0) }
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
        .reportPDFToolbar(title: "Capital Gains") { model.capitalGainsDocument() }
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

struct CashFlowView: View {
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
        Group {
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
        .reportPDFToolbar(title: "Forecast") { model.forecastDocument() }
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
