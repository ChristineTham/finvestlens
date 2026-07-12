//
//  PortfolioReportTests.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Portfolio report")
struct PortfolioReportTests {

    @Test("Values a holding and computes gain")
    func portfolio() {
        let book = Book(baseCurrency: .aud)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let shares = book.addAccount(Account(name: "CBA", type: .stock, commodity: cba))

        // Buy 10 CBA shares for $1,000 (cost basis).
        let buy = Transaction(currency: .aud, datePosted: day(2026, 1, 1), description: "Buy CBA")
        buy.addSplit(Split(account: shares, value: dec("1000"), quantity: dec("10")))
        buy.addSplit(account: bank, value: dec("-1000"))
        book.addTransaction(buy)

        // Price rises to $120/share.
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 2, 1), value: dec("120")))

        let portfolio = FinancialReports.portfolio(book, currency: .aud, asOf: day(2026, 3, 1))
        let holding = try? #require(portfolio.holdings.first)

        #expect(holding?.shares == dec("10"))
        #expect(holding?.costBasis == dec("1000"))
        #expect(holding?.price == dec("120"))
        #expect(holding?.marketValue == dec("1200"))
        #expect(holding?.gain == dec("200"))
        #expect(portfolio.totalValue == dec("1200"))
        #expect(portfolio.totalGain == dec("200"))
    }

    @Test("Unpriced holdings contribute cost but no market value")
    func unpriced() {
        let book = Book(baseCurrency: .aud)
        let xyz = Commodity(namespace: .security("ASX"), mnemonic: "XYZ",
                            fullName: "XYZ", smallestFraction: 10000)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let shares = book.addAccount(Account(name: "XYZ", type: .stock, commodity: xyz))
        let buy = Transaction(currency: .aud, datePosted: day(2026, 1, 1), description: "Buy")
        buy.addSplit(Split(account: shares, value: dec("500"), quantity: dec("5")))
        buy.addSplit(account: bank, value: dec("-500"))
        book.addTransaction(buy)

        let portfolio = FinancialReports.portfolio(book, currency: .aud)
        #expect(portfolio.holdings.first?.marketValue == nil)
        #expect(portfolio.holdings.first?.costBasis == dec("500"))
        #expect(portfolio.totalValue == dec("0"))
    }
}
