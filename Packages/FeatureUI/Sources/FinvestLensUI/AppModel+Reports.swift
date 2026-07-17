//
//  AppModel+Reports.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

@MainActor
extension AppModel {

    /// The currency used for single-currency reports (the book's base).
    var reportCurrency: Commodity {
        book?.commodities.first { $0.namespace == .currency } ?? .aud
    }

    public func balanceSheet(asOf: Date = Date()) -> BalanceSheet? {
        guard let book else { return nil }
        return FinancialReports.balanceSheet(book, asOf: asOf, currency: reportCurrency)
    }

    public func incomeStatement(from: Date, to: Date) -> IncomeStatement? {
        guard let book else { return nil }
        return FinancialReports.incomeStatement(book, from: from, to: to, currency: reportCurrency)
    }

    /// An account's postings over a period with a running balance (`FR-RPT-04`).
    public func transactionReport(accountID: GncGUID, from: Date, to: Date) -> TransactionReport? {
        guard let book else { return nil }
        return FinancialReports.transactionReport(book, accountID: accountID, from: from, to: to)
    }

    /// An account's postings grouped by reconcile state as of a date
    /// (`FR-RPT-05`).
    public func reconcileReport(accountID: GncGUID, asOf: Date) -> ReconcileReport? {
        guard let book else { return nil }
        return FinancialReports.reconcileReport(book, accountID: accountID, asOf: asOf)
    }

    /// Every account's balance in debit/credit columns (`FR-RPT-01`).
    public func trialBalance(asOf: Date) -> TrialBalanceReport? {
        guard let book else { return nil }
        return FinancialReports.trialBalance(book, asOf: asOf, currency: reportCurrency)
    }

    /// The movement of capital over a period (`FR-RPT-01`).
    public func equityStatement(from: Date, to: Date) -> EquityStatement? {
        guard let book else { return nil }
        return FinancialReports.equityStatement(book, from: from, to: to,
                                                currency: reportCurrency)
    }

    /// The chart of accounts with balances, cut at a depth (`FR-RPT-01`).
    public func accountSummary(asOf: Date, depthLimit: Int) -> AccountSummaryReport? {
        guard let book else { return nil }
        return FinancialReports.accountSummary(book, asOf: asOf, currency: reportCurrency,
                                               depthLimit: depthLimit)
    }

    /// Money into and out of a set of accounts over a period (`FR-RPT-01`).
    public func cashFlow(accountIDs: Set<GncGUID>, from: Date, to: Date) -> CashFlowReport? {
        guard let book, !accountIDs.isEmpty else { return nil }
        return FinancialReports.cashFlow(book, accountIDs: accountIDs, from: from, to: to,
                                         currency: reportCurrency)
    }

    /// The daily-weighted average balance of a set of accounts over a period,
    /// sliced by interval (`FR-RPT-03`).
    public func averageBalance(accountIDs: Set<GncGUID>, from: Date, to: Date,
                               step: AverageBalanceStep) -> AverageBalanceReport? {
        guard let book, !accountIDs.isEmpty else { return nil }
        let accounts = accountIDs.compactMap { book.account(with: $0) }
        guard !accounts.isEmpty else { return nil }
        return FinancialReports.averageBalance(book, accounts: accounts,
                                               currency: reportCurrency,
                                               from: from, to: to, step: step)
    }

    /// Income and spending by category and by month (`FR-RPT-03`).
    public func categoryBreakdown(from: Date, to: Date) -> CategoryBreakdown? {
        guard let book else { return nil }
        return FinancialReports.categoryBreakdown(book, from: from, to: to,
                                                  currency: reportCurrency)
    }

    /// A monthly net-worth series across the last `months` months.
    public func netWorthSeries(months: Int = 12, endingAt end: Date = Date()) -> [NetWorthPoint] {
        guard let book else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let dates: [Date] = (0..<max(1, months)).reversed().compactMap {
            calendar.date(byAdding: .month, value: -$0, to: end)
        }
        return FinancialReports.netWorthSeries(book, dates: dates, currency: reportCurrency)
    }
}
