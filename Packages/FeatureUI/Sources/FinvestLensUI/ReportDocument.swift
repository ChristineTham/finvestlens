//
//  ReportDocument.swift
//  FinvestLens — FeatureUI
//
//  A report as a document, not another register.
//
//  Every polished report is the same shape: a header naming the report and its
//  period, the few numbers it exists to produce (callouts), a chart where one
//  says something, tables with aligned numerals and ruled totals, and notes —
//  fixed methodology lines plus optional Apple Intelligence commentary. So that
//  shape is a value, `ReportDocument`, and one view renders it; the PDF export
//  consumes the same value, which is what keeps the print and the screen from
//  drifting apart.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
import FinvestLensEngine
import FinvestLensReports
import FinvestLensIntelligence

// MARK: - The value

/// One headline figure, displayed large.
struct ReportKPI: Identifiable {
    var id: String { label }
    var label: String
    var amount: Decimal
    /// Tint negative amounts red where sign carries meaning (net income);
    /// balances stay neutral.
    var signed = false
}

/// One line of a report table.
struct ReportDocumentRow: Identifiable {
    let id = UUID()
    var label: String
    /// Indentation level, 0 for a top-level row.
    var depth = 0
    /// The single amount, or —
    var amount: Decimal?
    /// — a debit/credit pair, for the trial balance's two columns.
    var debit: Decimal?
    var credit: Decimal?
    /// — several amounts, one per period, for a comparative statement. A `nil`
    /// entry renders blank (the account had no line in that period).
    var amounts: [Decimal?]?
}

/// A titled table with an optional ruled total.
struct ReportDocumentSection: Identifiable {
    var id: String { title }
    var title: String
    var rows: [ReportDocumentRow]
    var total: (label: String, amount: Decimal)? = nil
    /// Two amount columns instead of one (trial balance).
    var isDebitCredit = false
    /// Column headers, when the rows carry `amounts` (a comparative statement).
    var columns: [String]? = nil
    /// A ruled total across the comparative columns.
    var columnTotals: (label: String, amounts: [Decimal?])? = nil
}

/// The chart a report carries, when it carries one.
enum ReportDocumentChart {
    case monthlyBars([MonthlyFlow])
    case line([NetWorthPoint])
    case averageBars([AverageBalanceInterval])
    /// A composition donut (portfolio allocation): label + positive value.
    case allocation([(label: String, value: Decimal)])
}

/// A complete report, ready to render or print.
struct ReportDocument {
    var title: String
    var periodLabel: String
    var currencyCode: String
    var kpis: [ReportKPI]
    /// Deterministic plain-language reading of the figures, shown between the
    /// callouts and the chart (Spending Insights' sentences).
    var summary: [String] = []
    var chart: ReportDocumentChart?
    var sections: [ReportDocumentSection]
    /// Fixed methodology notes ("Securities valued at market…").
    var notes: [String]
    /// The facts commentary is narrated from, when the report offers it.
    var facts: ReportFactsSource?
}

extension ReportDocument {
    /// No figures anywhere — the report ran but had nothing to say.
    var isEmpty: Bool {
        kpis.isEmpty && summary.isEmpty && chart == nil
            && sections.allSatisfy { $0.rows.isEmpty }
    }
}

/// What the narrator gets: headline figures and ranked lines, no access to
/// anything it could miscompute.
struct ReportFactsSource {
    var headline: [(String, Decimal)]
    var lines: [(String, Decimal)]
}

// MARK: - Rendering

/// Renders a ``ReportDocument`` in the app's annual-report style.
struct ReportDocumentView: View {
    @Bindable var model: AppModel
    let document: ReportDocument
    @State private var commentary: [String]?
    @State private var narrating = false
    @State private var narrationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !document.kpis.isEmpty { kpiRow }
                if !document.summary.isEmpty { summaryBlock }
                if let chart = document.chart { chartView(chart) }
                ForEach(document.sections) { section in
                    ReportTableView(section: section, code: document.currencyCode)
                }
                notes
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        ReportMasthead(entity: model.statementEntityName,
                       title: document.title,
                       period: document.periodLabel,
                       code: document.currencyCode)
    }

    private var kpiRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(document.kpis) { kpi in
                VStack(alignment: .leading, spacing: 4) {
                    Text(kpi.label)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(AmountFormat.string(kpi.amount, code: document.currencyCode))
                        .scaledFont(.title2)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(kpi.signed && kpi.amount < 0 ? .red : .primary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// The deterministic plain-language reading, one sentence per line.
    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(document.summary, id: \.self) { line in
                Label {
                    Text(line).scaledFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func chartView(_ chart: ReportDocumentChart) -> some View {
        switch chart {
        case .monthlyBars(let months):
            Chart(months) { month in
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
            .frame(height: 200)
        case .line(let points):
            Chart(points) { point in
                LineMark(x: .value("Date", point.date),
                         y: .value("Net Worth", point.netWorth))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Date", point.date),
                         y: .value("Net Worth", point.netWorth))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.3), .clear],
                                                     startPoint: .top, endPoint: .bottom))
            }
            .frame(height: 200)
        case .averageBars(let intervals):
            Chart(intervals) { interval in
                BarMark(x: .value("Period", interval.start),
                        y: .value("Average",
                                  NSDecimalNumber(decimal: interval.average).doubleValue))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(height: 200)
        case .allocation(let slices):
            Chart(slices, id: \.label) { slice in
                SectorMark(angle: .value("Value",
                                         NSDecimalNumber(decimal: slice.value).doubleValue),
                           innerRadius: .ratio(0.6), angularInset: 1)
                    .cornerRadius(2)
                    .foregroundStyle(by: .value("Holding", slice.label))
            }
            .chartForegroundStyleScale(range: ReportPalette.categorical)
            .chartLegend(position: .trailing, alignment: .center)
            .frame(height: 220)
        }
    }

    @ViewBuilder
    private var notes: some View {
        if !document.notes.isEmpty || document.facts != nil {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Notes")
                    .scaledFont(.headline)
                ForEach(document.notes, id: \.self) { note in
                    Text(note)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if let commentary {
                    ForEach(commentary, id: \.self) { line in
                        Label {
                            Text(line).scaledFont(.callout)
                        } icon: {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text("Commentary is generated on-device from the figures above.")
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                } else if document.facts != nil, model.isIntelligenceAvailable {
                    Button {
                        narrate()
                    } label: {
                        Label(narrating ? "Writing commentary…" : "Add commentary",
                              systemImage: "sparkles")
                    }
                    .disabled(narrating)
                }
                if let narrationError {
                    Text(narrationError).scaledFont(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func narrate() {
        guard let facts = document.facts else { return }
        narrating = true
        narrationError = nil
        let request = ReportFacts(reportTitle: document.title,
                                  periodLabel: document.periodLabel,
                                  currencyCode: document.currencyCode,
                                  headline: facts.headline, lines: facts.lines)
        Task {
            defer { narrating = false }
            do { commentary = try await model.reportCommentary(for: request) }
            catch { narrationError = error.localizedDescription }
        }
    }
}

/// One table: label column, amount column(s), rules, a bold total.
struct ReportTableView: View {
    let section: ReportDocumentSection
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .scaledFont(.headline)
                .padding(.bottom, 6)
            Divider()
            if let columns = section.columns {
                comparativeGrid(columns)
            } else {
                singleGrid
            }
        }
    }

    private var singleGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            if section.isDebitCredit {
                GridRow {
                    Text("")
                    Text("Debit").gridColumnAlignment(.trailing)
                    Text("Credit").gridColumnAlignment(.trailing)
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                GridRow {
                    Text(row.label)
                        .padding(.leading, CGFloat(row.depth) * 16)
                        .foregroundStyle(row.depth > 0 ? .secondary : .primary)
                    if section.isDebitCredit {
                        amountText(row.debit).gridColumnAlignment(.trailing)
                        amountText(row.credit).gridColumnAlignment(.trailing)
                    } else {
                        amountText(row.amount).gridColumnAlignment(.trailing)
                    }
                }
                .scaledFont(.body)
                .padding(.vertical, 5)
                .background(index.isMultiple(of: 2) ? Color.clear
                            : Color.primary.opacity(0.03))
            }
            if let total = section.total {
                GridRow {
                    Text(total.label).fontWeight(.bold)
                    if section.isDebitCredit {
                        Text("").gridColumnAlignment(.trailing)
                        amountText(total.amount).fontWeight(.bold)
                            .gridColumnAlignment(.trailing)
                    } else {
                        amountText(total.amount).fontWeight(.bold)
                            .gridColumnAlignment(.trailing)
                    }
                }
                .scaledFont(.body)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    /// One period per column, amounts right-aligned under each header.
    private func comparativeGrid(_ columns: [String]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Text("")
                ForEach(Array(columns.enumerated()), id: \.offset) { _, header in
                    Text(header).gridColumnAlignment(.trailing)
                }
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                GridRow {
                    Text(row.label)
                        .padding(.leading, CGFloat(row.depth) * 16)
                        .foregroundStyle(row.depth > 0 ? .secondary : .primary)
                    ForEach(Array((row.amounts ?? []).enumerated()), id: \.offset) { _, amount in
                        amountText(amount).gridColumnAlignment(.trailing)
                    }
                }
                .scaledFont(.body)
                .padding(.vertical, 5)
                .background(index.isMultiple(of: 2) ? Color.clear
                            : Color.primary.opacity(0.03))
            }
            if let totals = section.columnTotals {
                GridRow {
                    Text(totals.label).fontWeight(.bold)
                    ForEach(Array(totals.amounts.enumerated()), id: \.offset) { _, amount in
                        amountText(amount).fontWeight(.bold).gridColumnAlignment(.trailing)
                    }
                }
                .scaledFont(.body)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    @ViewBuilder
    private func amountText(_ amount: Decimal?) -> some View {
        if let amount {
            Text(AmountFormat.string(amount, code: code))
                .monospacedDigit()
                .foregroundStyle(amount < 0 ? .red : .primary)
        } else {
            Text("")
        }
    }
}

// MARK: - Print

extension ReportDocument {
    /// The same document as a printable statement — one source for screen and
    /// paper.
    var printable: PrintableStatement {
        var sections: [PrintableSection] = []
        if !kpis.isEmpty {
            sections.append(PrintableSection(heading: "Summary", rows:
                kpis.map { PrintableRow(label: $0.label, amount: $0.amount, bold: true) }))
        }
        if !summary.isEmpty {
            // Text-only rows: the single nil amount column renders blank.
            sections.append(PrintableSection(heading: "In brief", rows:
                summary.map { PrintableRow(label: $0, amount: 0, amounts: [nil]) }))
        }
        for section in self.sections {
            if let columns = section.columns {
                var rows = section.rows.map {
                    PrintableRow(label: String(repeating: "    ", count: $0.depth) + $0.label,
                                 amount: 0, amounts: $0.amounts)
                }
                if let totals = section.columnTotals {
                    rows.append(PrintableRow(label: totals.label, amount: 0, bold: true,
                                             amounts: totals.amounts))
                }
                sections.append(PrintableSection(heading: section.title, rows: rows,
                                                 columns: columns))
                continue
            }
            var rows = section.rows.map {
                PrintableRow(label: String(repeating: "    ", count: $0.depth) + $0.label,
                             amount: $0.amount ?? $0.debit ?? ($0.credit.map { -$0 }) ?? 0)
            }
            if let total = section.total {
                rows.append(PrintableRow(label: total.label, amount: total.amount, bold: true))
            }
            sections.append(PrintableSection(heading: section.title, rows: rows))
        }
        return PrintableStatement(title: title,
                                  subtitle: "\(periodLabel) · \(currencyCode)",
                                  code: currencyCode,
                                  sections: sections)
    }
}
