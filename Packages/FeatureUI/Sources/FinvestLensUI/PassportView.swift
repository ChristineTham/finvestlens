//
//  PassportView.swift
//  FinvestLens — FeatureUI
//
//  The financial summary "passport" (`FR-PLAN-17`, docs/planning-design.md
//  §6): a curated, user-initiated snapshot — net worth and its 12-month
//  trend, assets and liabilities by class, income, expenses, and the savings
//  rate — in the statement typography, exportable as a one-page PDF. Nothing
//  leaves the machine except the file the user saves.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
import FinvestLensEngine
import FinvestLensReports

struct PassportData {
    var title: String
    var asOf: Date
    var currencyCode: String
    var netWorth: Decimal
    var trend: [NetWorthPoint]
    var assetClasses: [(name: String, value: Decimal)]
    var liabilityClasses: [(name: String, value: Decimal)]
    var income12M: Decimal
    var expenses12M: Decimal

    var totalAssets: Decimal { assetClasses.reduce(0) { $0 + $1.value } }
    var totalLiabilities: Decimal { liabilityClasses.reduce(0) { $0 + $1.value } }
    var savingsRate: Decimal? {
        income12M > 0 ? (income12M - expenses12M) / income12M : nil
    }
}

@MainActor
extension AppModel {

    /// Assembles the passport from the same machinery the statements use.
    func passportData() -> PassportData? {
        guard let book else { return nil }
        let now = Self.endOfToday()
        let calendar = Calendar.current
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now

        guard let statement = financialPositionStatement(asOf: now) else { return nil }
        func classes(_ sectionTitle: String) -> [(name: String, value: Decimal)] {
            guard let section = statement.sections.first(where: { $0.title.localizedCaseInsensitiveContains(sectionTitle) })
            else { return [] }
            return section.items.compactMap { item -> (name: String, value: Decimal)? in
                guard item.role == .line,
                      let amount = item.amounts.first ?? nil, amount != 0 else { return nil }
                return (item.caption, amount)
            }
        }

        let dates = (0...12).compactMap { calendar.date(byAdding: .month, value: -$0, to: now) }.reversed()
        let trend = FinancialReports.netWorthSeries(book, dates: Array(dates), currency: reportCurrency)
        let breakdown = FinancialReports.categoryBreakdown(book, from: yearAgo, to: now,
                                                           currency: reportCurrency)

        return PassportData(
            title: documentURL?.deletingPathExtension().lastPathComponent ?? "Financial Summary",
            asOf: now,
            currencyCode: reportCurrency.mnemonic,
            netWorth: trend.last?.netWorth ?? 0,
            trend: trend,
            assetClasses: classes("Assets"),
            liabilityClasses: classes("Liabilit"),
            income12M: breakdown.totalIncome,
            expenses12M: breakdown.totalExpenses)
    }
}

struct PassportSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var exportDocument: PDFReportDocument?

    var body: some View {
        NavigationStack {
            Group {
                if let data = model.passportData() {
                    ScrollView {
                        PassportPage(data: data)
                            .padding(24)
                    }
                } else {
                    ContentUnavailableView("No book open", systemImage: "doc")
                }
            }
            .navigationTitle("Financial Summary")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem {
                    Button("Export PDF…", systemImage: "arrow.up.doc") { export() }
                        .help("Save the one-page summary as a PDF")
                }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument,
                          contentType: .pdf,
                          defaultFilename: "Financial Summary") { _ in }
        }
        .frame(minWidth: 640, minHeight: 700)
    }

    private func export() {
        guard let data = model.passportData() else { return }
        let page = PassportPage(data: data)
            .frame(width: 595, height: 842)          // A4 portrait, points
        guard let pdf = ReportExport.pdfPage(page, size: CGSize(width: 595, height: 842))
        else { return }
        exportDocument = PDFReportDocument(data: pdf)
        exporting = true
    }
}

/// The page itself — statement typography, paper-like regardless of theme.
struct PassportPage: View {
    let data: PassportData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(data.title)
                    .scaledFont(.title, weight: .semibold, design: .serif)
                Text("Financial summary as of \(data.asOf.formatted(date: .long, time: .omitted))")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("NET WORTH").scaledFont(.caption2, weight: .semibold).kerning(1)
                        .foregroundStyle(.secondary)
                    Text(AmountFormat.string(data.netWorth, code: data.currencyCode))
                        .scaledFont(.largeTitle, weight: .bold, design: .serif)
                        .monospacedDigit()
                }
                Spacer()
                if let rate = data.savingsRate {
                    VStack(alignment: .trailing) {
                        Text("SAVINGS RATE (12 MO)").scaledFont(.caption2, weight: .semibold).kerning(1)
                            .foregroundStyle(.secondary)
                        Text("\(SpendingInsights.wholePercent(rate * 100))%")
                            .scaledFont(.title, weight: .semibold, design: .serif)
                    }
                }
            }

            if data.trend.count > 1 {
                Chart(data.trend) { point in
                    LineMark(x: .value("Date", point.date),
                             y: .value("Net worth", NSDecimalNumber(decimal: point.netWorth).doubleValue))
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Date", point.date),
                             y: .value("Net worth", NSDecimalNumber(decimal: point.netWorth).doubleValue))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.2), .clear],
                                                         startPoint: .top, endPoint: .bottom))
                }
                .frame(height: 130)
                .accessibilityLabel("Net worth over the last twelve months")
            }

            HStack(alignment: .top, spacing: 24) {
                classTable("Assets", rows: data.assetClasses, total: data.totalAssets)
                classTable("Liabilities", rows: data.liabilityClasses, total: data.totalLiabilities)
            }

            VStack(alignment: .leading, spacing: 4) {
                heading("Last 12 months")
                row("Income", data.income12M)
                row("Expenses", data.expenses12M)
                row("Net saved", data.income12M - data.expenses12M, bold: true)
            }

            Spacer(minLength: 0)
            Text("Prepared with FinvestLens from the owner's own records — a snapshot, not a verified statement.")
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func classTable(_ title: String, rows: [(name: String, value: Decimal)],
                            total: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            heading(title)
            ForEach(rows, id: \.name) { entry in
                row(entry.name, entry.value)
            }
            Divider()
            row("Total \(title.lowercased())", total, bold: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(.caption, weight: .semibold)
            .kerning(1)
            .foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: Decimal, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(AmountFormat.string(value, code: data.currencyCode))
                .monospacedDigit()
        }
        .scaledFont(.callout, weight: bold ? .semibold : .regular)
    }
}
