//
//  AppModel+ReportDocuments.swift
//  FinvestLens — FeatureUI
//
//  Printable ``ReportDocument`` builders for the interactive reports
//  (`FR-RPT-05`). Each keeps its live view; these give the same figures a
//  static, paginated form so the report scaffold's PDF export covers them too.
//  One builder per report, from the report type the view already computes.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

@MainActor
extension AppModel {

    private func shortDate(_ date: Date) -> String {
        AppDateFormat.current.long(date)
    }

    /// A period label "1 Jan 2026 – 31 Mar 2026".
    private func range(_ from: Date, _ to: Date) -> String {
        "\(shortDate(from)) – \(shortDate(to))"
    }

    // MARK: Spending Insights (FR-PLAN-13)

    func spendingInsightsDocument(period: ReportPeriod) -> ReportDocument? {
        guard let insights = spendingInsights(period: period) else { return nil }
        let code = insights.currencyCode
        func money(_ value: Decimal) -> String { AmountFormat.string(value, code: code) }

        func comparison(_ title: String, rows: [CategoryComparison],
                        totalCurrent: Decimal, totalPrior: Decimal) -> ReportDocumentSection? {
            guard !rows.isEmpty else { return nil }
            return ReportDocumentSection(
                title: title,
                rows: rows.map { row in
                    ReportDocumentRow(label: row.name + (row.isNew ? " (new)" : (row.isGone ? " (gone)" : "")),
                                      amounts: [row.current, row.prior, row.delta])
                },
                columns: ["This period", "Prior", "Change"],
                columnTotals: ("Total", [totalCurrent, totalPrior, totalCurrent - totalPrior]))
        }

        return ReportDocument(
            title: "Spending Insights",
            periodLabel: "\(label(for: period)) · vs \(range(insights.priorFrom, insights.priorTo))",
            currencyCode: code,
            kpis: [ReportKPI(label: "Spending", amount: insights.totalSpendingCurrent),
                   ReportKPI(label: "Income", amount: insights.totalIncomeCurrent),
                   ReportKPI(label: "Net saved",
                             amount: insights.totalIncomeCurrent - insights.totalSpendingCurrent,
                             signed: true)],
            summary: insights.summary(format: money),
            chart: nil,
            sections: [
                comparison("Spending by category", rows: insights.expenses,
                           totalCurrent: insights.totalSpendingCurrent,
                           totalPrior: insights.totalSpendingPrior),
                comparison("Income", rows: insights.income,
                           totalCurrent: insights.totalIncomeCurrent,
                           totalPrior: insights.totalIncomePrior),
            ].compactMap { $0 },
            notes: ["Compared against the immediately-preceding period of the same length. "
                    + "Categories are top-level, subtrees rolled up — the same figures as the "
                    + "income & expense breakdown."],
            facts: ReportFactsSource(
                headline: [("Spending", insights.totalSpendingCurrent),
                           ("Prior spending", insights.totalSpendingPrior),
                           ("Income", insights.totalIncomeCurrent)],
                lines: insights.expenses.prefix(12).map { ($0.name, $0.delta) }))
    }

    // MARK: Transactions (FR-RPT-01)

    func transactionsDocument(accountID: GncGUID, from: Date, to: Date) -> ReportDocument? {
        guard let report = transactionReport(accountID: accountID, from: from, to: to) else { return nil }
        let rows = report.rows.map { row in
            ReportDocumentRow(label: "\(shortDate(row.date))  \(row.description)",
                              amounts: [row.amount, row.balance])
        }
        return ReportDocument(
            title: "Transactions — \(accountName(accountID) ?? "Account")",
            periodLabel: range(from, to), currencyCode: report.currencyCode,
            kpis: [ReportKPI(label: "Opening", amount: report.opening),
                   ReportKPI(label: "Net change", amount: report.total, signed: true),
                   ReportKPI(label: "Closing", amount: report.closing)],
            chart: nil,
            sections: [ReportDocumentSection(
                title: "Postings", rows: rows,
                columns: ["Amount", "Balance"],
                columnTotals: ("Closing balance", [report.total, report.closing]))],
            notes: [], facts: nil)
    }

    // MARK: Reconciliation (FR-RPT-04)

    func reconcileDocument(accountID: GncGUID, asOf: Date) -> ReportDocument? {
        guard let report = reconcileReport(accountID: accountID, asOf: asOf) else { return nil }
        func rows(_ list: [ReconcileReportRow]) -> [ReportDocumentRow] {
            list.map { ReportDocumentRow(label: "\(shortDate($0.date))  \($0.description)", amount: $0.amount) }
        }
        return ReportDocument(
            title: "Reconciliation — \(accountName(accountID) ?? "Account")",
            periodLabel: "As of \(shortDate(asOf))", currencyCode: report.currencyCode,
            kpis: [ReportKPI(label: "Reconciled", amount: report.reconciledBalance),
                   ReportKPI(label: "Cleared", amount: report.clearedBalance),
                   ReportKPI(label: "Ending", amount: report.endingBalance)],
            chart: nil,
            sections: [
                ReportDocumentSection(title: "Funds In", rows: rows(report.fundsIn),
                                      total: ("Total in", report.totalIn)),
                ReportDocumentSection(title: "Funds Out", rows: rows(report.fundsOut),
                                      total: ("Total out", report.totalOut)),
                ReportDocumentSection(title: "Cleared — not yet reconciled", rows: rows(report.cleared),
                                      total: ("Cleared total", report.clearedTotal)),
                ReportDocumentSection(title: "Outstanding — not on a statement", rows: rows(report.outstanding),
                                      total: ("Outstanding total", report.outstandingTotal)),
            ],
            notes: report.isConsistent ? [] : ["The sections above do not sum to the ending balance — the account may hold edits newer than its last reconciliation."],
            facts: nil)
    }

    // MARK: Portfolio (FR-RPT-02)

    func portfolioDocument(asOf: Date = Date()) -> ReportDocument? {
        guard let portfolio = advancedPortfolio(asOf: asOf) else { return nil }
        let code = portfolio.currencyCode
        let rows = portfolio.holdings.map { h -> ReportDocumentRow in
            let detail = "\(h.symbol)  \(h.shares.formatted()) sh"
                + (h.income != 0 ? "  · income \(AmountFormat.string(h.income, code: code))" : "")
            return ReportDocumentRow(label: detail, amount: h.marketValue ?? 0)
        }
        var kpis = [ReportKPI(label: "Cost basis", amount: portfolio.totalCost),
                    ReportKPI(label: "Market value", amount: portfolio.totalValue),
                    ReportKPI(label: "Unrealized", amount: portfolio.totalUnrealized, signed: true)]
        if portfolio.totalIncome != 0 {
            kpis.append(ReportKPI(label: "Income", amount: portfolio.totalIncome))
        }
        // The allocation donut: the largest holdings by value, the tail rolled
        // into "Other" so the legend stays legible.
        let valued = portfolio.holdings
            .compactMap { h in (h.marketValue ?? 0) > 0 ? (h.symbol, h.marketValue!) : nil }
            .sorted { $0.1 > $1.1 }
        var slices = valued.prefix(9).map { (label: $0.0, value: $0.1) }
        let tail = valued.dropFirst(9).reduce(Decimal(0)) { $0 + $1.1 }
        if tail > 0 { slices.append((label: "Other", value: tail)) }

        return ReportDocument(
            title: "Portfolio", periodLabel: "As of \(shortDate(asOf))", currencyCode: code,
            kpis: kpis, chart: slices.count > 1 ? .allocation(slices) : nil,
            sections: [ReportDocumentSection(title: "Holdings", rows: rows,
                                             total: ("Market value", portfolio.totalValue))],
            notes: ["Securities valued at their most recent price; unpriced holdings show zero value."],
            facts: nil)
    }

    // MARK: Investment lots (FR-RPT-02)

    func investmentLotsDocument(asOf: Date = Date()) -> ReportDocument? {
        let lots = investmentLots(asOf: asOf)
        guard !lots.isEmpty else { return nil }
        let code = reportCurrency.mnemonic
        let rows = lots.map { lot -> ReportDocumentRow in
            let acquired = lot.acquisitionDate.map { " acq \(shortDate($0))" } ?? ""
            return ReportDocumentRow(
                label: "\(lot.symbol)  \(lot.quantity.formatted()) @ cost "
                    + "\(AmountFormat.string(lot.costBasis, code: code))\(acquired)",
                amount: lot.marketValue ?? lot.costBasis)
        }
        let totalCost = lots.reduce(Decimal(0)) { $0 + $1.costBasis }
        return ReportDocument(
            title: "Investment Lots", periodLabel: "As of \(shortDate(asOf))", currencyCode: code,
            kpis: [ReportKPI(label: "Open lots", amount: Decimal(lots.count)),
                   ReportKPI(label: "Cost basis", amount: totalCost)],
            chart: nil,
            sections: [ReportDocumentSection(title: "Open Lots (\(costBasisMethod.displayName))",
                                             rows: rows, total: ("Cost basis", totalCost))],
            notes: [], facts: nil)
    }

    // MARK: Capital gains (FR-RPT-03)

    func capitalGainsDocument(from: Date = .distantPast, to: Date = .distantFuture) -> ReportDocument? {
        guard let report = capitalGains(from: from, to: to) else { return nil }
        let code = report.currencyCode
        let rows = report.lines.map { line -> ReportDocumentRow in
            let term = line.longTerm == true ? " (LT)" : line.longTerm == false ? " (ST)" : ""
            return ReportDocumentRow(
                label: "\(line.symbol)\(term)  \(line.quantity.formatted()) sold \(shortDate(line.disposalDate))",
                amount: line.gain)
        }
        return ReportDocument(
            title: "Capital Gains", periodLabel: "\(report.method.displayName) cost basis",
            currencyCode: code,
            kpis: [ReportKPI(label: "Short-term", amount: report.shortTermGain, signed: true),
                   ReportKPI(label: "Long-term", amount: report.longTermGain, signed: true),
                   ReportKPI(label: "Total realised", amount: report.totalGain, signed: true)],
            chart: nil,
            sections: rows.isEmpty ? [] : [ReportDocumentSection(
                title: "Realised Gains", rows: rows, total: ("Total realised", report.totalGain))],
            notes: report.lines.isEmpty ? ["No realised gains in this period."] : [],
            facts: nil)
    }

    // MARK: Price history (FR-RPT — Price Scatter)

    func priceHistoryDocument() -> ReportDocument? {
        let securities = securitiesWithPriceHistory
        guard !securities.isEmpty else { return nil }
        let code = reportCurrency.mnemonic
        let rows = securities.compactMap { commodity -> ReportDocumentRow? in
            let history = priceHistory(for: commodity).sorted { $0.date < $1.date }
            guard let latest = history.last else { return nil }
            return ReportDocumentRow(
                label: "\(commodity.mnemonic)  \(history.count) prices, latest \(shortDate(latest.date))",
                amount: latest.value)
        }
        guard !rows.isEmpty else { return nil }
        return ReportDocument(
            title: "Price History", periodLabel: "Latest prices", currencyCode: code,
            kpis: [], chart: nil,
            sections: [ReportDocumentSection(title: "Securities", rows: rows)],
            notes: ["The interactive report plots every price over time; this lists each security's latest price."],
            facts: nil)
    }

    // MARK: Cash-flow forecast (FR-RPT — Forecast)

    func forecastDocument() -> ReportDocument? {
        guard let accountID = defaultForecastAccountID else { return nil }
        let points = cashFlowForecast(accountID: accountID)
        let events = points.filter { $0.change != 0 }
        guard !events.isEmpty else { return nil }
        let code = reportCurrency.mnemonic
        let rows = events.map { event in
            ReportDocumentRow(label: "\(shortDate(event.date))  \(event.label)"
                              + (event.isWhatIf ? " (what-if)" : ""),
                              amounts: [event.change, event.balance])
        }
        return ReportDocument(
            title: "Cash-Flow Forecast — \(accountName(accountID) ?? "Account")",
            periodLabel: "Projected from scheduled transactions", currencyCode: code,
            kpis: [ReportKPI(label: "Ending balance", amount: points.last?.balance ?? 0, signed: true)],
            chart: nil,
            sections: [ReportDocumentSection(
                title: "Upcoming Activity", rows: rows, columns: ["Change", "Balance"])],
            notes: [], facts: nil)
    }
}
