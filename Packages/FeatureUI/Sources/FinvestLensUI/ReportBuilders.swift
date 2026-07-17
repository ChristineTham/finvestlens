//
//  ReportBuilders.swift
//  FinvestLens — FeatureUI
//
//  From a configuration to a document: resolve the period under the book's
//  financial-year convention, run the engine computation (one book walk since
//  the one-pass rewrite), and lay the result out as KPIs, tables, charts and
//  notes. The builders are the only place a report's presentation is decided,
//  and the PDF prints the same value.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

@MainActor
extension AppModel {

    /// The default scope for the cash-flow report: the accounts statements
    /// arrive for. Money is *followed through* bank and cash accounts; an
    /// expense account has no statement to check against.
    var defaultCashFlowAccountIDs: Set<GncGUID> {
        guard let book else { return [] }
        return Set(book.accounts
            .filter { !$0.isPlaceholder && ($0.type == .bank || $0.type == .cash) }
            .map(\.guid))
    }

    /// Net worth at each month end across a window — the chart the dashboard
    /// draws, generalised to any period.
    func netWorthPoints(from: Date, to: Date) -> [NetWorthPoint] {
        guard let book else { return [] }
        // All-time starts where the book does, not at the epoch.
        let earliest = book.transactions.map(\.datePosted).min() ?? to
        let start = max(from, earliest)
        let calendar = Calendar.current

        var dates: [Date] = []
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
        while cursor <= to {
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: cursor)!
            dates.append(min(nextMonth.addingTimeInterval(-1), to))
            cursor = nextMonth
        }
        if dates.isEmpty { dates = [to] }
        return FinancialReports.netWorthSeries(book, dates: dates, currency: reportCurrency)
    }

    /// Builds the document for a scaffold report, or `nil` for kinds that keep
    /// interactive views (or a book that is not open).
    func reportDocument(for configuration: ReportConfiguration) -> ReportDocument? {
        guard book != nil, let kind = ReportKind(rawValue: configuration.kind),
              kind.usesScaffold else { return nil }

        let (from, to) = resolve(configuration.period)
        let asOfLabel = "As of \(to.formatted(date: .long, time: .omitted))"
        let periodLabel = kind.isAsOf ? asOfLabel : label(for: configuration.period)

        switch kind {
        case .balanceSheet:
            guard let sheet = balanceSheet(asOf: to) else { return nil }
            return ReportDocument(
                title: "Balance Sheet",
                periodLabel: periodLabel,
                currencyCode: sheet.currencyCode,
                kpis: [
                    ReportKPI(label: "Assets", amount: sheet.totalAssets),
                    ReportKPI(label: "Liabilities", amount: sheet.totalLiabilities),
                    ReportKPI(label: "Net worth",
                              amount: sheet.totalAssets - sheet.totalLiabilities, signed: true),
                ],
                chart: nil,
                sections: [
                    section("Assets", sheet.assets, total: ("Total Assets", sheet.totalAssets)),
                    section("Liabilities", sheet.liabilities,
                            total: ("Total Liabilities", sheet.totalLiabilities)),
                    ReportDocumentSection(
                        title: "Equity",
                        rows: sheet.equity.map { line in
                            ReportDocumentRow(label: line.fullName, amount: line.amount)
                        } + [ReportDocumentRow(label: "Retained earnings",
                                               amount: sheet.retainedEarnings)],
                        total: ("Total Equity", sheet.totalEquity)),
                ],
                notes: [valuationNote(to),
                        "Retained earnings fold lifetime income less expenses into equity, "
                        + "so the sheet balances."],
                facts: ReportFactsSource(
                    headline: [("Assets", sheet.totalAssets),
                               ("Liabilities", sheet.totalLiabilities),
                               ("Equity", sheet.totalEquity)],
                    lines: ranked(sheet.assets + sheet.liabilities)))

        case .incomeStatement:
            guard let statement = incomeStatement(from: from, to: to) else { return nil }
            return ReportDocument(
                title: "Income Statement",
                periodLabel: periodLabel,
                currencyCode: statement.currencyCode,
                kpis: [
                    ReportKPI(label: "Income", amount: statement.totalIncome),
                    ReportKPI(label: "Expenses", amount: statement.totalExpenses),
                    ReportKPI(label: "Net income", amount: statement.netIncome, signed: true),
                ],
                chart: nil,
                sections: [
                    section("Income", statement.income,
                            total: ("Total Income", statement.totalIncome)),
                    section("Expenses", statement.expenses,
                            total: ("Total Expenses", statement.totalExpenses)),
                ],
                notes: [valuationNote(to)],
                facts: ReportFactsSource(
                    headline: [("Income", statement.totalIncome),
                               ("Expenses", statement.totalExpenses),
                               ("Net income", statement.netIncome)],
                    lines: ranked(statement.income + statement.expenses)))

        case .equityStatement:
            guard let statement = equityStatement(from: from, to: to) else { return nil }
            return ReportDocument(
                title: "Equity Statement",
                periodLabel: periodLabel,
                currencyCode: statement.currencyCode,
                kpis: [
                    ReportKPI(label: "Opening capital", amount: statement.openingCapital),
                    ReportKPI(label: "Closing capital", amount: statement.closingCapital),
                    ReportKPI(label: "Net income", amount: statement.netIncome, signed: true),
                ],
                chart: nil,
                sections: [ReportDocumentSection(
                    title: "Movement in capital",
                    rows: [
                        ReportDocumentRow(label: "Opening capital",
                                          amount: statement.openingCapital),
                        ReportDocumentRow(label: "Net income", amount: statement.netIncome),
                        ReportDocumentRow(label: "Contributions",
                                          amount: statement.contributions),
                        ReportDocumentRow(label: "Withdrawals",
                                          amount: -statement.withdrawals),
                        ReportDocumentRow(label: "Unrealised gains and FX",
                                          amount: statement.unrealisedChange),
                    ],
                    total: ("Closing capital", statement.closingCapital))],
                notes: ["The unrealised line is the valuation change the period's postings "
                        + "cannot account for: market moves and FX revaluation.",
                        valuationNote(to)],
                facts: ReportFactsSource(
                    headline: [("Opening capital", statement.openingCapital),
                               ("Closing capital", statement.closingCapital),
                               ("Net income", statement.netIncome),
                               ("Unrealised change", statement.unrealisedChange)],
                    lines: []))

        case .trialBalance:
            guard let report = trialBalance(asOf: to) else { return nil }
            return ReportDocument(
                title: "Trial Balance",
                periodLabel: periodLabel,
                currencyCode: report.currencyCode,
                kpis: [
                    ReportKPI(label: "Debits", amount: report.totalDebits),
                    ReportKPI(label: "Credits", amount: report.totalCredits),
                    ReportKPI(label: "Unrealised adjustment",
                              amount: report.unrealisedAdjustment, signed: true),
                ],
                chart: nil,
                sections: [ReportDocumentSection(
                    title: "Balances",
                    rows: report.rows.map { row in
                        ReportDocumentRow(label: row.fullName,
                                          debit: row.debit, credit: row.credit)
                    },
                    total: ("Totals", report.totalDebits),
                    isDebitCredit: true)],
                notes: ["Balances in the raw double-entry convention. The unrealised "
                        + "adjustment is what valuing holdings at market adds over cost — "
                        + "printed, not hidden, because it is the number that makes the "
                        + "columns agree.",
                        valuationNote(to)],
                facts: nil)

        case .accountSummary:
            let depth = configuration.depth ?? 2
            guard let report = accountSummary(asOf: to, depthLimit: depth) else { return nil }
            let assets = report.sections.first { $0.title == "Assets" }?.total ?? 0
            let liabilities = report.sections.first { $0.title == "Liabilities" }?.total ?? 0
            return ReportDocument(
                title: "Account Summary",
                periodLabel: periodLabel,
                currencyCode: report.currencyCode,
                kpis: [
                    ReportKPI(label: "Assets", amount: assets),
                    ReportKPI(label: "Liabilities", amount: liabilities),
                    ReportKPI(label: "Net worth", amount: assets - liabilities, signed: true),
                ],
                chart: nil,
                sections: report.sections.map { section in
                    ReportDocumentSection(
                        title: section.title,
                        rows: section.rows.map { row in
                            ReportDocumentRow(label: row.name, depth: row.depth - 1,
                                              amount: row.balance)
                        },
                        total: ("Total \(section.title)", section.total))
                },
                notes: ["Accounts deeper than level \(depth) roll into their ancestor, so "
                        + "every depth sums to the same totals. Income and expense balances "
                        + "are lifetime to date.",
                        valuationNote(to)],
                facts: nil)

        case .netWorth:
            let points = netWorthPoints(from: from, to: to)
            guard let first = points.first, let last = points.last else { return nil }
            return ReportDocument(
                title: "Net Worth",
                periodLabel: periodLabel,
                currencyCode: reportCurrency.mnemonic,
                kpis: [
                    ReportKPI(label: "Start", amount: first.netWorth),
                    ReportKPI(label: "End", amount: last.netWorth),
                    ReportKPI(label: "Change",
                              amount: last.netWorth - first.netWorth, signed: true),
                ],
                chart: .line(points),
                sections: [],
                notes: ["Month-end net worth: assets less liabilities, converted at each "
                        + "date's rates.", valuationNote(to)],
                facts: ReportFactsSource(
                    headline: [("Start", first.netWorth), ("End", last.netWorth),
                               ("Change", last.netWorth - first.netWorth)],
                    lines: []))

        case .cashFlow:
            let scope = configuration.accountIDs ?? defaultCashFlowAccountIDs
            guard let report = cashFlow(accountIDs: scope, from: from, to: to) else { return nil }
            return ReportDocument(
                title: "Cash Flow",
                periodLabel: periodLabel,
                currencyCode: report.currencyCode,
                kpis: [
                    ReportKPI(label: "Money in", amount: report.totalIn),
                    ReportKPI(label: "Money out", amount: report.totalOut),
                    ReportKPI(label: "Net change", amount: report.netChange, signed: true),
                ],
                chart: nil,
                sections: [
                    section("Money in, from", report.inflows,
                            total: ("Total in", report.totalIn)),
                    section("Money out, to", report.outflows,
                            total: ("Total out", report.totalOut)),
                ],
                notes: ["Flows through \(report.accountNames.count) account(s): "
                        + report.accountNames.joined(separator: ", ") + ".",
                        "Transfers wholly inside the selected accounts are internal and "
                        + "excluded; by double entry, in minus out equals their net change."],
                facts: ReportFactsSource(
                    headline: [("Money in", report.totalIn), ("Money out", report.totalOut),
                               ("Net change", report.netChange)],
                    lines: ranked(report.inflows + report.outflows)))

        case .incomeExpense:
            guard let breakdown = categoryBreakdown(from: from, to: to) else { return nil }
            return ReportDocument(
                title: "Income & Expense",
                periodLabel: periodLabel,
                currencyCode: breakdown.currencyCode,
                kpis: [
                    ReportKPI(label: "Income", amount: breakdown.totalIncome),
                    ReportKPI(label: "Expenses", amount: breakdown.totalExpenses),
                    ReportKPI(label: "Net",
                              amount: breakdown.totalIncome - breakdown.totalExpenses,
                              signed: true),
                ],
                chart: .monthlyBars(breakdown.months),
                sections: [
                    section("Spending by category", breakdown.expenseSlices,
                            total: ("Total Expenses", breakdown.totalExpenses)),
                    section("Income by category", breakdown.incomeSlices,
                            total: ("Total Income", breakdown.totalIncome)),
                ],
                notes: ["Categories are top-level accounts with their subtrees rolled up; "
                        + "the slices sum to the income statement for the same period."],
                facts: ReportFactsSource(
                    headline: [("Income", breakdown.totalIncome),
                               ("Expenses", breakdown.totalExpenses)],
                    lines: ranked(breakdown.expenseSlices + breakdown.incomeSlices)))

        case .averageBalance:
            let scope = configuration.accountIDs ?? defaultCashFlowAccountIDs
            let step = configuration.step ?? .month
            guard let report = averageBalance(accountIDs: scope, from: from, to: to,
                                              step: step) else { return nil }
            let average = report.overallAverage ?? 0
            return ReportDocument(
                title: "Average Balance",
                periodLabel: periodLabel,
                currencyCode: report.currencyCode,
                kpis: [
                    ReportKPI(label: "Average balance", amount: average),
                    ReportKPI(label: "Total in", amount: report.totalGain),
                    ReportKPI(label: "Total out", amount: report.totalLoss),
                ],
                chart: report.intervals.isEmpty ? nil : .averageBars(report.intervals),
                sections: [
                    ReportDocumentSection(
                        title: "Average balance by \(step.displayName.lowercased())",
                        rows: report.intervals.map { interval in
                            ReportDocumentRow(label: intervalLabel(interval),
                                              amount: interval.average)
                        },
                        total: ("Weighted average", average)),
                ],
                notes: ["Balances are sampled at each day's end; an interval's average is "
                        + "the mean of its daily balances. Across "
                        + "\(report.accountNames.count) account(s): "
                        + report.accountNames.joined(separator: ", ") + ".",
                        "Foreign-currency accounts convert at each day's rate; an account "
                        + "with no rate contributes nothing that day."],
                facts: ReportFactsSource(
                    headline: [("Average balance", average), ("Total in", report.totalGain),
                               ("Total out", report.totalLoss)],
                    lines: report.intervals.map { (intervalLabel($0), $0.average) }))

        default:
            return nil
        }
    }

    /// A short label for one average-balance interval — the start date, since
    /// intervals abut (each ends the day before the next begins).
    private func intervalLabel(_ interval: AverageBalanceInterval) -> String {
        interval.start.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Helpers

    private func section(_ title: String, _ lines: [ReportLine],
                         total: (String, Decimal)) -> ReportDocumentSection {
        ReportDocumentSection(
            title: title,
            rows: lines.map { ReportDocumentRow(label: $0.fullName, amount: $0.amount) },
            total: total)
    }

    private func ranked(_ lines: [ReportLine]) -> [(String, Decimal)] {
        lines.sorted { abs($0.amount) > abs($1.amount) }
            .prefix(12)
            .map { ($0.fullName, $0.amount) }
    }

    private func valuationNote(_ date: Date) -> String {
        "Security holdings are valued at market using the latest price on or before "
        + date.formatted(date: .abbreviated, time: .omitted)
        + "; foreign currencies convert at that date's rate. Accounts with no available "
        + "price are omitted."
    }
}
