//
//  AdvancedPortfolioTests.swift
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
private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }

@Suite("Advanced portfolio")
struct AdvancedPortfolioTests {

    private func security(_ mnemonic: String) -> Commodity {
        Commodity(namespace: .security("ASX"), mnemonic: mnemonic, fullName: mnemonic, smallestFraction: 10000)
    }

    /// Buy 10 CBA @ $10, sell 4 @ $15 (realized +20), 6 remain @ $10 cost.
    private func book() -> (Book, Account) {
        let cba = security("CBA")
        let book = Book(baseCurrency: .aud)
        let stock = Account(name: "CBA", type: .stock, commodity: cba)
        book.addAccount(stock)
        let buy = Transaction(currency: .aud, datePosted: day(0), description: "Buy")
        buy.addSplit(account: stock, value: dec("100"), quantity: dec("10"))
        buy.addSplit(account: book.rootAccount, value: dec("-100"))
        book.addTransaction(buy)
        let sell = Transaction(currency: .aud, datePosted: day(400), description: "Sell")
        sell.addSplit(account: stock, value: dec("-60"), quantity: dec("-4"))
        sell.addSplit(account: book.rootAccount, value: dec("60"))
        book.addTransaction(sell)
        // Mark at $12.
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(410), value: dec("12")))
        return (book, stock)
    }

    @Test("Cost basis reflects only remaining shares; realized carried")
    func lotTied() {
        let (book, _) = book()
        let report = FinancialReports.advancedPortfolio(book, currency: .aud, asOf: day(420))
        let h = report.holdings.first!
        #expect(h.shares == dec("6"))
        #expect(h.costBasis == dec("60"))         // 6 × $10
        #expect(h.averageCost == dec("10"))
        #expect(h.marketValue == dec("72"))       // 6 × $12
        #expect(h.unrealizedGain == dec("12"))
        #expect(h.realizedGain == dec("20"))      // from the sale
    }

    @Test("Money In / Money Out / rate of return (FR-RPT-02)")
    func moneyFlows() {
        let (book, _) = book()
        let report = FinancialReports.advancedPortfolio(book, currency: .aud, asOf: day(420))
        let h = report.holdings.first!
        #expect(h.moneyIn == dec("100"))          // 10 shares acquired @ $10
        #expect(h.moneyOut == dec("60"))          // 4 sold @ $15
        // (unrealized 12 + realized 20) / money-in 100 = 0.32.
        #expect(h.returnFraction != nil)
        #expect(abs((h.returnFraction ?? 0) - 0.32) < 1e-9)
        #expect(report.totalMoneyIn == dec("100"))
        #expect(report.totalMoneyOut == dec("60"))
    }

    @Test("Allocation sums to ~1 across priced holdings")
    func allocation() {
        let (book, _) = book()
        // Add a second holding so allocation is meaningful.
        let bhp = security("BHP")
        let stock2 = Account(name: "BHP", type: .stock, commodity: bhp)
        book.addAccount(stock2)
        let buy = Transaction(currency: .aud, datePosted: day(0), description: "Buy BHP")
        buy.addSplit(account: stock2, value: dec("72"), quantity: dec("2"))
        buy.addSplit(account: book.rootAccount, value: dec("-72"))
        book.addTransaction(buy)
        book.addPrice(Price(commodity: bhp, currency: .aud, date: day(410), value: dec("36")))

        let report = FinancialReports.advancedPortfolio(book, currency: .aud, asOf: day(420))
        let total = report.holdings.compactMap(\.allocation).reduce(0, +)
        #expect(abs(total - 1.0) < 0.0001)
        // Both holdings are $72 → 50/50.
        #expect(report.holdings.allSatisfy { abs(($0.allocation ?? 0) - 0.5) < 0.0001 })
        #expect(report.totalValue == dec("144"))
    }

    @Test("Totals aggregate cost, value, unrealized and realized")
    func totals() {
        let (book, _) = book()
        let report = FinancialReports.advancedPortfolio(book, currency: .aud, asOf: day(420))
        #expect(report.totalCost == dec("60"))
        #expect(report.totalValue == dec("72"))
        #expect(report.totalUnrealized == dec("12"))
        #expect(report.totalRealized == dec("20"))
    }

    @Test("Unpriced holding still appears without a market value")
    func unpriced() {
        let cba = security("XYZ")
        let book = Book(baseCurrency: .aud)
        let stock = Account(name: "XYZ", type: .stock, commodity: cba)
        book.addAccount(stock)
        let buy = Transaction(currency: .aud, datePosted: day(0), description: "Buy")
        buy.addSplit(account: stock, value: dec("100"), quantity: dec("10"))
        buy.addSplit(account: book.rootAccount, value: dec("-100"))
        book.addTransaction(buy)

        let report = FinancialReports.advancedPortfolio(book, currency: .aud)
        #expect(report.holdings.first?.marketValue == nil)
        #expect(report.holdings.first?.allocation == nil)
        #expect(report.holdings.first?.costBasis == dec("100"))
    }
}
