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
