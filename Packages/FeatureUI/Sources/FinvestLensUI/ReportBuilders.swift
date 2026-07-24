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
        let asOfLabel = "As of \(AppDateFormat.current.full(to))"
        let periodLabel = kind.isAsOf ? asOfLabel : label(for: configuration.period)

        switch kind {
        case .balanceSheet:
            if let columns = comparisonColumns(configuration.period,
                                               extra: configuration.comparePeriods ?? 0) {
                return comparativeBalanceSheet(columns)
            }
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
            if let columns = comparisonColumns(configuration.period,
                                               extra: configuration.comparePeriods ?? 0) {
                return comparativeIncomeStatement(columns)
            }
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
                        title: "By \(step.displayName.lowercased())",
                        rows: report.intervals.map { interval in
                            ReportDocumentRow(
                                label: intervalLabel(interval),
                                amounts: [interval.average, interval.minimum, interval.maximum,
                                          interval.gain, interval.loss])
                        },
                        columns: ["Average", "Minimum", "Maximum", "Gain", "Loss"],
                        columnTotals: ("Weighted average / totals",
                                       [average, nil, nil, report.totalGain, report.totalLoss])),
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

        case .receivableAging, .payableAging:
            let receivable = kind == .receivableAging
            guard let book else { return nil }
            let rows = book.agingByOwner(receivable: receivable, asOf: to)
            let code = reportCurrency.mnemonic
            let columns = ["Current", "31–60", "61–90", "91+", "Total"]
            func amounts(_ b: AgingBuckets) -> [Decimal?] {
                [b.current, b.days31to60, b.days61to90, b.over90, b.total]
            }
            let totals = rows.reduce(into: AgingBuckets()) { acc, row in
                acc.current += row.buckets.current
                acc.days31to60 += row.buckets.days31to60
                acc.days61to90 += row.buckets.days61to90
                acc.over90 += row.buckets.over90
            }
            return ReportDocument(
                title: receivable ? "Receivable Aging" : "Payable Aging",
                periodLabel: asOfLabel,
                currencyCode: code,
                kpis: [
                    ReportKPI(label: receivable ? "Owed to you" : "You owe", amount: totals.total),
                    ReportKPI(label: "Current", amount: totals.current),
                    ReportKPI(label: "Over 90 days", amount: totals.over90, signed: true),
                ],
                chart: nil,
                sections: [ReportDocumentSection(
                    title: receivable ? "Customers" : "Vendors",
                    rows: rows.map { ReportDocumentRow(label: $0.name, amounts: amounts($0.buckets)) },
                    columns: columns,
                    columnTotals: ("Total", amounts(totals)))],
                notes: ["Open invoices are aged by their due date as of "
                        + AppDateFormat.current.long(to)
                        + " into 0–30 (current), 31–60, 61–90 and 91+ day buckets."],
                facts: ReportFactsSource(
                    headline: [("Total", totals.total), ("Current", totals.current),
                               ("Over 90 days", totals.over90)],
                    lines: rows.map { ($0.name, $0.buckets.total) }))

        case .customerSummary:
            guard let book else { return nil }
            return ownerSummary(title: "Customer Summary", chargedNoun: "Invoiced",
                                entity: "Customers", asOf: to, asOfLabel: asOfLabel,
                                owners: book.customers.map { ($0.guid, $0.name) })

        case .vendorSummary:
            guard let book else { return nil }
            return ownerSummary(title: "Vendor Summary", chargedNoun: "Billed",
                                entity: "Vendors", asOf: to, asOfLabel: asOfLabel,
                                owners: book.vendors.map { ($0.guid, $0.name) })

        case .employeeSummary:
            guard let book else { return nil }
            return ownerSummary(title: "Employee Summary", chargedNoun: "Claimed",
                                entity: "Employees", asOf: to, asOfLabel: asOfLabel,
                                owners: book.employees.map { ($0.guid, $0.username) })

        case .jobSummary:
            guard let book else { return nil }
            return ownerSummary(title: "Job Summary", chargedNoun: "Invoiced",
                                entity: "Jobs", asOf: to, asOfLabel: asOfLabel,
                                owners: book.jobs.map { ($0.guid, $0.name) })

        case .spendingInsights:
            return spendingInsightsDocument(period: configuration.period)
        case .transactions:
            guard let account = configuration.accountIDs?.first ?? selectedAccountID
                ?? postableAccounts.first?.id else { return nil }
            return transactionsDocument(accountID: account, from: from, to: to)
        case .reconcile:
            guard let account = configuration.accountIDs?.first ?? selectedAccountID
                ?? postableAccounts.first?.id else { return nil }
            return reconcileDocument(accountID: account, asOf: to)
        case .portfolio:
            return portfolioDocument(asOf: to)
        case .investmentLots:
            return investmentLotsDocument(asOf: to)
        case .capitalGains:
            return capitalGainsDocument(from: from, to: to)
        default:
            return nil
        }
    }

    /// One row per party — charged / paid / outstanding over its posted
    /// documents, most-charged first — the shared shape behind the Customer,
    /// Vendor, Employee and Job summaries (GnuCash's per-owner reports). Parties
    /// with no posted document are omitted.
    private func ownerSummary(title: String, chargedNoun: String, entity: String,
                              asOf to: Date, asOfLabel: String,
                              owners: [(guid: GncGUID, name: String)]) -> ReportDocument? {
        guard let book else { return nil }
        let code = reportCurrency.mnemonic
        struct Row { var name: String; var charged: Decimal = 0; var outstanding: Decimal = 0 }
        var rows: [Row] = []
        for owner in owners {
            let posted = book.invoices(forOwner: owner.guid).filter { $0.isPosted }
            guard !posted.isEmpty else { continue }
            var row = Row(name: owner.name)
            for invoice in posted {
                row.charged += invoice.total
                row.outstanding += book.outstanding(invoice)
            }
            rows.append(row)
        }
        rows.sort { $0.charged > $1.charged }
        let columns = [chargedNoun, "Paid", "Outstanding"]
        func amounts(_ r: Row) -> [Decimal?] {
            [r.charged, r.charged - r.outstanding, r.outstanding]
        }
        let totalCharged = rows.reduce(Decimal(0)) { $0 + $1.charged }
        let totalOutstanding = rows.reduce(Decimal(0)) { $0 + $1.outstanding }
        return ReportDocument(
            title: title,
            periodLabel: asOfLabel,
            currencyCode: code,
            kpis: [
                ReportKPI(label: "Total \(chargedNoun.lowercased())", amount: totalCharged),
                ReportKPI(label: "Paid", amount: totalCharged - totalOutstanding),
                ReportKPI(label: "Outstanding", amount: totalOutstanding),
            ],
            chart: nil,
            sections: [ReportDocumentSection(
                title: entity,
                rows: rows.map { ReportDocumentRow(label: $0.name, amounts: amounts($0)) },
                columns: columns,
                columnTotals: ("Total",
                               [totalCharged, totalCharged - totalOutstanding, totalOutstanding]))],
            notes: ["Totals cover posted documents only, as of "
                    + AppDateFormat.current.long(to)
                    + ". \"Paid\" is \(chargedNoun.lowercased()) less what is still outstanding."],
            facts: ReportFactsSource(
                headline: [(chargedNoun, totalCharged), ("Paid", totalCharged - totalOutstanding),
                           ("Outstanding", totalOutstanding)],
                lines: rows.map { ($0.name, $0.charged) }))
    }

    /// A short label for one average-balance interval — the start date, since
    /// intervals abut (each ends the day before the next begins).
    private func intervalLabel(_ interval: AverageBalanceInterval) -> String {
        AppDateFormat.current.long(interval.start)
    }

    // MARK: Comparative statements

    /// The period columns for a comparative statement: the selected period plus
    /// `extra` earlier periods of the same length, most recent first. `nil` when
    /// no comparison is asked for, or the period does not tile the calendar.
    func comparisonColumns(_ period: ReportPeriod, extra: Int)
        -> [(label: String, from: Date, to: Date)]? {
        guard extra > 0, let stride = period.comparisonStride else { return nil }
        let calendar = Calendar.current
        var back = DateComponents()
        back.year = stride.year.map { -$0 }
        back.month = stride.month.map { -$0 }
        back.day = stride.day.map { -$0 }

        var columns: [(label: String, from: Date, to: Date)] = []
        var (from, to) = resolve(period)
        for _ in 0...extra {
            columns.append((comparisonLabel(from: from, to: to, stride: stride), from, to))
            from = calendar.date(byAdding: back, to: from)!
            to = calendar.date(byAdding: back, to: to)!
        }
        return columns
    }

    /// A compact column header for one comparative period, from its window and
    /// the stride: "FY 2024–25", "2025", "Q3 2025", or "Aug 2025".
    private func comparisonLabel(from: Date, to: Date, stride: DateComponents) -> String {
        let calendar = Calendar.current
        let fromMonth = calendar.component(.month, from: from)
        let fromYear = calendar.component(.year, from: from)
        let toYear = calendar.component(.year, from: to)
        if stride.year == 1 {
            return fromMonth == 1 ? "\(fromYear)"
                : "FY \(fromYear)–\(String(format: "%02d", toYear % 100))"
        }
        if stride.month == 3 {
            return "Q\((fromMonth - 1) / 3 + 1) \(fromYear)"
        }
        if stride.month == 1 {
            return AppDateFormat.current.monthYear(from)
        }
        return AppDateFormat.current.long(to)
    }

    /// Aligns report lines from several periods into comparative rows, keyed by
    /// full account name and ordered by first appearance across the columns. A
    /// `nil` amount means the account had no line in that period.
    private func alignedRows(_ columns: [[ReportLine]],
                             extra: [(label: String, amounts: [Decimal?])] = [])
        -> [ReportDocumentRow] {
        var order: [String] = []
        var seen = Set<String>()
        for column in columns {
            for line in column where seen.insert(line.fullName).inserted {
                order.append(line.fullName)
            }
        }
        let maps = columns.map { column in
            Dictionary(column.map { ($0.fullName, $0.amount) },
                       uniquingKeysWith: { first, _ in first })
        }
        var rows = order.map { key in
            ReportDocumentRow(label: key, amounts: maps.map { $0[key] })
        }
        rows += extra.map { ReportDocumentRow(label: $0.label, amounts: $0.amounts) }
        return rows
    }

    private func comparativeBalanceSheet(
        _ columns: [(label: String, from: Date, to: Date)]
    ) -> ReportDocument? {
        let sheets = columns.compactMap { balanceSheet(asOf: $0.to) }
        guard sheets.count == columns.count, let current = sheets.first else { return nil }
        let headers = columns.map(\.label)
        let equityExtra = [(label: "Retained earnings",
                            amounts: sheets.map { Optional($0.retainedEarnings) })]

        return ReportDocument(
            title: "Balance Sheet",
            periodLabel: "Comparative · " + headers.joined(separator: " vs "),
            currencyCode: current.currencyCode,
            kpis: [
                ReportKPI(label: "Assets", amount: current.totalAssets),
                ReportKPI(label: "Liabilities", amount: current.totalLiabilities),
                ReportKPI(label: "Net worth",
                          amount: current.totalAssets - current.totalLiabilities, signed: true),
            ],
            chart: nil,
            sections: [
                ReportDocumentSection(
                    title: "Assets", rows: alignedRows(sheets.map { $0.assets }),
                    columns: headers,
                    columnTotals: ("Total Assets", sheets.map { Optional($0.totalAssets) })),
                ReportDocumentSection(
                    title: "Liabilities", rows: alignedRows(sheets.map { $0.liabilities }),
                    columns: headers,
                    columnTotals: ("Total Liabilities", sheets.map { Optional($0.totalLiabilities) })),
                ReportDocumentSection(
                    title: "Equity",
                    rows: alignedRows(sheets.map { $0.equity }, extra: equityExtra),
                    columns: headers,
                    columnTotals: ("Total Equity", sheets.map { Optional($0.totalEquity) })),
            ],
            notes: [valuationNote(columns[0].to),
                    "Columns compare the selected period with earlier periods of the same "
                    + "length; the leftmost is the most recent."],
            facts: ReportFactsSource(
                headline: [("Assets", current.totalAssets),
                           ("Liabilities", current.totalLiabilities),
                           ("Equity", current.totalEquity)],
                lines: ranked(current.assets + current.liabilities)))
    }

    private func comparativeIncomeStatement(
        _ columns: [(label: String, from: Date, to: Date)]
    ) -> ReportDocument? {
        let statements = columns.compactMap { incomeStatement(from: $0.from, to: $0.to) }
        guard statements.count == columns.count, let current = statements.first else { return nil }
        let headers = columns.map(\.label)

        return ReportDocument(
            title: "Income Statement",
            periodLabel: "Comparative · " + headers.joined(separator: " vs "),
            currencyCode: current.currencyCode,
            kpis: [
                ReportKPI(label: "Income", amount: current.totalIncome),
                ReportKPI(label: "Expenses", amount: current.totalExpenses),
                ReportKPI(label: "Net income", amount: current.netIncome, signed: true),
            ],
            chart: nil,
            sections: [
                ReportDocumentSection(
                    title: "Income", rows: alignedRows(statements.map { $0.income }),
                    columns: headers,
                    columnTotals: ("Total Income", statements.map { Optional($0.totalIncome) })),
                ReportDocumentSection(
                    title: "Expenses", rows: alignedRows(statements.map { $0.expenses }),
                    columns: headers,
                    columnTotals: ("Total Expenses", statements.map { Optional($0.totalExpenses) })),
                ReportDocumentSection(
                    title: "Result", rows: [], columns: headers,
                    columnTotals: ("Net income", statements.map { Optional($0.netIncome) })),
            ],
            notes: [valuationNote(columns[0].to),
                    "Columns compare the selected period with earlier periods of the same "
                    + "length; the leftmost is the most recent."],
            facts: ReportFactsSource(
                headline: [("Income", current.totalIncome),
                           ("Expenses", current.totalExpenses),
                           ("Net income", current.netIncome)],
                lines: ranked(current.income + current.expenses)))
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
        + AppDateFormat.current.long(date)
        + "; foreign currencies convert at that date's rate. Accounts with no available "
        + "price are omitted."
    }
}
