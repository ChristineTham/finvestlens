//
//  ComparativeStatementTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Comparative statements")
struct ComparativeStatementTests {

    /// Places income in the current and previous financial years (resolved the
    /// same way the report does, so the test is independent of today's date),
    /// then checks the comparative income statement aligns and totals per period.
    @Test("Income statement compares periods, columns agree with per-period totals")
    func incomeStatementColumns() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bankID = try #require(model.addAccount(name: "Bank", type: .bank))
        let salaryID = try #require(model.addAccount(name: "Salary", type: .income))
        let calendar = Calendar.current
        func midpoint(_ window: (from: Date, to: Date)) -> Date {
            calendar.date(byAdding: .day, value: 15, to: window.from)!
        }
        func earn(_ date: Date, _ amount: String) throws {
            try model.addTransaction(date: date, description: "Pay", currency: .aud, splits: [
                SplitInput(accountID: bankID, value: dec(amount), quantity: dec(amount)),
                SplitInput(accountID: salaryID, value: -dec(amount)),
            ])
        }
        try earn(midpoint(model.resolve(.currentFinancialYear)), "1000")
        try earn(midpoint(model.resolve(.previousFinancialYear)), "700")

        let config = ReportConfiguration(
            kind: ReportKind.incomeStatement.rawValue,
            period: .currentFinancialYear, comparePeriods: 1)
        let document = try #require(model.reportDocument(for: config))

        // Two columns; the leftmost is the current (anchor) period.
        let income = try #require(document.sections.first { $0.title == "Income" })
        let headers = try #require(income.columns)
        #expect(headers.count == 2)
        let totals = try #require(income.columnTotals?.amounts)
        #expect(totals == [dec("1000"), dec("700")])

        // The columns equal the standalone per-period income statements.
        let (curFrom, curTo) = model.resolve(.currentFinancialYear)
        let (prevFrom, prevTo) = model.resolve(.previousFinancialYear)
        #expect(model.incomeStatement(from: curFrom, to: curTo)?.totalIncome == dec("1000"))
        #expect(model.incomeStatement(from: prevFrom, to: prevTo)?.totalIncome == dec("700"))

        // Net income appears as its own comparative row.
        let result = try #require(document.sections.first { $0.title == "Result" })
        #expect(result.columnTotals?.amounts == [dec("1000"), dec("700")])
        #expect(document.periodLabel.hasPrefix("Comparative"))
    }

    /// A balance sheet at successive year-ends compares as-of balances.
    @Test("Balance sheet shows an equity row per period and totals that balance")
    func balanceSheetColumns() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bankID = try #require(model.addAccount(name: "Bank", type: .bank))
        let openingID = try #require(model.addAccount(name: "Opening", type: .equity))
        let calendar = Calendar.current
        func deposit(_ window: (from: Date, to: Date), _ amount: String) throws {
            let date = calendar.date(byAdding: .day, value: 15, to: window.from)!
            try model.addTransaction(date: date, description: "Open", currency: .aud, splits: [
                SplitInput(accountID: bankID, value: dec(amount), quantity: dec(amount)),
                SplitInput(accountID: openingID, value: -dec(amount)),
            ])
        }
        // Balance grows across the two years: +5000 last FY, +3000 this FY → 8000 now.
        try deposit(model.resolve(.previousFinancialYear), "5000")
        try deposit(model.resolve(.currentFinancialYear), "3000")

        let config = ReportConfiguration(
            kind: ReportKind.balanceSheet.rawValue,
            period: .currentFinancialYear, comparePeriods: 1)
        let document = try #require(model.reportDocument(for: config))

        let assets = try #require(document.sections.first { $0.title == "Assets" })
        #expect(assets.columns?.count == 2)
        // Current column (left) = 8000, prior column (right) = 5000.
        #expect(assets.columnTotals?.amounts == [dec("8000"), dec("5000")])

        // Assets equal liabilities + equity in every column (the sheet balances).
        let liabilities = try #require(document.sections.first { $0.title == "Liabilities" })
        let equity = try #require(document.sections.first { $0.title == "Equity" })
        for column in 0..<2 {
            let a = assets.columnTotals!.amounts[column] ?? 0
            let l = liabilities.columnTotals!.amounts[column] ?? 0
            let e = equity.columnTotals!.amounts[column] ?? 0
            #expect(a == l + e)
        }
    }

    @Test("A period that does not tile the calendar suppresses comparison columns")
    func nonTilingPeriodIsSingleColumn() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = try #require(model.addAccount(name: "Bank", type: .bank))

        // All time has no natural stride: asking to compare yields one column.
        #expect(model.comparisonColumns(.allTime, extra: 2) == nil)
        let config = ReportConfiguration(
            kind: ReportKind.balanceSheet.rawValue,
            period: .allTime, comparePeriods: 2)
        let document = try #require(model.reportDocument(for: config))
        #expect(document.sections.first { $0.title == "Assets" }?.columns == nil)
    }
}
