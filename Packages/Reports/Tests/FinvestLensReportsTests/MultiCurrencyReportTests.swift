//
//  MultiCurrencyReportTests.swift
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

@Suite("Multi-currency reports")
struct MultiCurrencyReportTests {

    /// AUD base with an AUD bank ($1,000) and a USD bank ($200 @ 1.50 = $300 AUD).
    private func book() -> Book {
        let book = Book(baseCurrency: .aud)
        let audBank = Account(name: "AUD Bank", type: .bank, commodity: .aud)
        let usdBank = Account(name: "USD Bank", type: .bank, commodity: .usd)
        let opening = Account(name: "Opening", type: .equity, commodity: .aud)
        book.addAccount(audBank); book.addAccount(usdBank); book.addAccount(opening)
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(0))

        let t1 = Transaction(currency: .aud, datePosted: day(1), description: "AUD deposit")
        t1.addSplit(account: audBank, value: dec("1000"))
        t1.addSplit(account: opening, value: dec("-1000"))
        book.addTransaction(t1)

        let t2 = Transaction(currency: .usd, datePosted: day(1), description: "USD deposit")
        t2.addSplit(account: usdBank, value: dec("200"))
        t2.addSplit(account: opening, value: dec("-200")) // opening in USD terms for this leg
        book.addTransaction(t2)
        return book
    }

    @Test("Balance sheet converts foreign cash into the base currency")
    func balanceSheet() {
        let sheet = FinancialReports.balanceSheet(book(), asOf: day(10), currency: .aud)
        // Assets = 1000 AUD + 300 AUD (200 USD × 1.50) = 1300.
        #expect(sheet.totalAssets == dec("1300"))
        #expect(sheet.assets.contains { $0.name == "USD Bank" && $0.amount == dec("300") })
    }

    @Test("Net worth values foreign balances at the FX rate")
    func netWorth() {
        let points = FinancialReports.netWorthSeries(book(), dates: [day(10)], currency: .aud)
        #expect(points.first?.assets == dec("1300"))
        #expect(points.first?.netWorth == dec("1300"))
    }

    @Test("Balance sheet and net worth value security holdings at market")
    func securitiesValued() {
        let b = Book(baseCurrency: .aud)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA.AX",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let bank = b.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let shares = b.addAccount(Account(name: "CBA", type: .stock, commodity: cba))

        // Buy 100 CBA for $10,000; price later $171.57 → market value $17,157.
        let buy = Transaction(currency: .aud, datePosted: day(1), description: "Buy CBA")
        buy.addSplit(Split(account: shares, value: dec("10000"), quantity: dec("100")))
        buy.addSplit(account: bank, value: dec("-10000"))
        b.addTransaction(buy)
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(5), value: dec("171.57")))

        let sheet = FinancialReports.balanceSheet(b, asOf: day(10), currency: .aud)
        // Bank −10,000 + CBA 17,157 = 7,157.
        #expect(sheet.assets.contains { $0.name == "CBA" && $0.amount == dec("17157") })
        #expect(sheet.totalAssets == dec("7157"))

        let nw = FinancialReports.netWorthSeries(b, dates: [day(10)], currency: .aud)
        #expect(nw.first?.assets == dec("7157"))
    }

    @Test("Rate change moves the converted balance")
    func rateChange() {
        let b = book()
        b.setExchangeRate(from: .usd, to: .aud, rate: dec("1.60"), date: day(5))
        let sheet = FinancialReports.balanceSheet(b, asOf: day(10), currency: .aud)
        // 1000 + 200 × 1.60 = 1320.
        #expect(sheet.totalAssets == dec("1320"))
    }

    @Test("Portfolio values a foreign security via its quote currency")
    func foreignSecurity() {
        let b = Book(baseCurrency: .aud)
        let aapl = Commodity(namespace: .security("NASDAQ"), mnemonic: "AAPL",
                             fullName: "Apple", smallestFraction: 10000)
        let holding = Account(name: "AAPL", type: .stock, commodity: aapl)
        b.addAccount(holding)
        b.addPrice(Price(commodity: aapl, currency: .usd, date: day(0), value: dec("200")))
        b.setExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(0))
        let buy = Transaction(currency: .usd, datePosted: day(1), description: "Buy 10")
        buy.addSplit(account: holding, value: dec("2000"), quantity: dec("10"))
        buy.addSplit(account: b.rootAccount, value: dec("-2000"))
        b.addTransaction(buy)

        let portfolio = FinancialReports.portfolio(b, currency: .aud, asOf: day(10))
        // 10 × 200 USD × 1.50 = 3000 AUD.
        #expect(portfolio.holdings.first?.marketValue == dec("3000"))
    }

    @Test("Single-currency book is unchanged")
    func singleCurrency() {
        let b = Book(baseCurrency: .aud)
        let bank = Account(name: "Bank", type: .bank, commodity: .aud)
        let opening = Account(name: "Opening", type: .equity, commodity: .aud)
        b.addAccount(bank); b.addAccount(opening)
        let t = Transaction(currency: .aud, datePosted: day(1), description: "Deposit")
        t.addSplit(account: bank, value: dec("500"))
        t.addSplit(account: opening, value: dec("-500"))
        b.addTransaction(t)
        let sheet = FinancialReports.balanceSheet(b, asOf: day(10), currency: .aud)
        #expect(sheet.totalAssets == dec("500"))
        #expect(sheet.isBalanced)
    }
}
