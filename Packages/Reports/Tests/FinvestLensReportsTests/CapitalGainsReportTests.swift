//
//  CapitalGainsReportTests.swift
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

@Suite("Capital gains report")
struct CapitalGainsReportTests {

    private func bookWithTrades() -> (Book, Account) {
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let book = Book(baseCurrency: .aud)
        let stock = Account(name: "CBA", type: .stock, commodity: cba)
        let cash = Account(name: "Cash", type: .bank, commodity: .aud)
        book.addAccount(stock); book.addAccount(cash)

        // Buy 10 @ $10 (day 0), sell 5 @ $15 (day 400, long term),
        // sell 3 @ $12 (day 430, long term).
        let buy = Transaction(currency: .aud, datePosted: day(0), description: "Buy")
        buy.addSplit(account: stock, value: dec("100"), quantity: dec("10"))
        buy.addSplit(account: cash, value: dec("-100"))
        book.addTransaction(buy)

        let sell1 = Transaction(currency: .aud, datePosted: day(400), description: "Sell 5")
        sell1.addSplit(account: stock, value: dec("-75"), quantity: dec("-5"))
        sell1.addSplit(account: cash, value: dec("75"))
        book.addTransaction(sell1)

        let sell2 = Transaction(currency: .aud, datePosted: day(430), description: "Sell 3")
        sell2.addSplit(account: stock, value: dec("-36"), quantity: dec("-3"))
        sell2.addSplit(account: cash, value: dec("36"))
        book.addTransaction(sell2)

        return (book, stock)
    }

    @Test("Aggregates realised gains and open lots")
    func aggregate() {
        let (book, _) = bookWithTrades()
        let report = FinancialReports.capitalGains(book, currency: .aud, method: .fifo)
        // Sold 8 for 111, cost 80 → gain 31. 2 remain, cost 20.
        #expect(report.lines.count == 2)
        #expect(report.totalProceeds == dec("111"))
        #expect(report.totalCostBasis == dec("80"))
        #expect(report.totalGain == dec("31"))
        #expect(report.longTermGain == dec("31"))
        #expect(report.shortTermGain == 0)
        #expect(report.openCostBasis == dec("20"))
    }

    @Test("Date window filters disposals")
    func window() {
        let (book, _) = bookWithTrades()
        let report = FinancialReports.capitalGains(book, currency: .aud,
                                                   from: day(410), to: day(500), method: .fifo)
        // Only the day-430 sale falls in the window.
        #expect(report.lines.count == 1)
        #expect(report.lines.first?.disposalDate == day(430))
        // Open lots are always reported regardless of the window.
        #expect(report.openLots.isEmpty == false)
    }

    @Test("Short-term sale is classified as short term")
    func shortTerm() {
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "X",
                            fullName: "X", smallestFraction: 10000)
        let book = Book(baseCurrency: .aud)
        let stock = Account(name: "X", type: .stock, commodity: cba)
        book.addAccount(stock)
        let buy = Transaction(currency: .aud, datePosted: day(0), description: "Buy")
        buy.addSplit(account: stock, value: dec("100"), quantity: dec("10"))
        book.addTransaction(buy)
        let sell = Transaction(currency: .aud, datePosted: day(30), description: "Sell")
        sell.addSplit(account: stock, value: dec("-130"), quantity: dec("-10"))
        book.addTransaction(sell)

        let report = FinancialReports.capitalGains(book, currency: .aud, method: .fifo)
        #expect(report.shortTermGain == dec("30"))
        #expect(report.longTermGain == 0)
    }
}
