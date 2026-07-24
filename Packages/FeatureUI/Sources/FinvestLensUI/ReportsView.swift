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
            VStack(alignment: .leading, spacing: 0) {
                ReportMasthead(entity: model.statementEntityName,
                               title: "Price History",
                               period: "All recorded security prices",
                               code: model.reportCurrency.mnemonic)
                    .padding(.top, 12)
                Chart(data) { point in
                    PointMark(x: .value("Date", point.date),
                              y: .value("Price", point.price))
                        .foregroundStyle(by: .value("Security", point.symbol))
                }
                .chartForegroundStyleScale(range: ReportPalette.categorical)
                .frame(minHeight: 260)
                .padding()
                .accessibilityLabel("Price scatter of all securities over time")
            }
        }
        }
        .reportPDFToolbar(title: "Price History", entity: model.statementEntityName) { model.priceHistoryDocument() }
    }
}

struct ForecastView: View {
    @Environment(\.appDateFormat) private var dateFormat
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
                ReportMasthead(entity: model.statementEntityName,
                               title: "Forecast",
                               period: model.accountName(accountID) ?? "Projected balances",
                               code: model.reportCurrency.mnemonic)
                    .padding(.top, 12)
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
                            // Hypotheticals in a reserved tint, distinct from
                            // the accent-coloured actual projection.
                            PointMark(x: .value("Date", point.date), y: .value("Balance", point.balance))
                                .foregroundStyle(.purple)
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
                            Text(dateFormat.short(event.date))
                                .foregroundStyle(.secondary)
                                .frame(width: dateWidth, alignment: .leading)
                            Text(event.label)
                            if event.isWhatIf {
                                Text("what-if").scaledFont(.caption2)
                                    .padding(.horizontal, 4).background(.purple.opacity(0.2)).clipShape(Capsule())
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
        .reportPDFToolbar(title: "Forecast", entity: model.statementEntityName) { model.forecastDocument() }
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
                    Text("\(event.label): \(AmountFormat.string(event.amount, code: model.reportCurrency.mnemonic)) on \(dateFormat.short(event.date))")
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
