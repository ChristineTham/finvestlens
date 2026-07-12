//
//  BookFXTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }

@Suite("Book FX")
struct BookFXTests {

    @Test("Direct and inverse rates")
    func rates() {
        let book = Book(baseCurrency: .aud)
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(0))
        #expect(book.exchangeRate(from: .usd, to: .aud) == dec("1.50"))
        // Inverse derived when only the reciprocal is stored.
        #expect(book.exchangeRate(from: .aud, to: .usd) == dec("1") / dec("1.50"))
        #expect(book.exchangeRate(from: .aud, to: .aud) == 1)
        #expect(book.exchangeRate(from: .eur, to: .aud) == nil)
    }

    @Test("Convert uses the latest rate on or before the date")
    func convertByDate() {
        let book = Book(baseCurrency: .aud)
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.40"), date: day(0))
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.55"), date: day(100))
        #expect(book.convert(dec("100"), from: .usd, to: .aud, on: day(50)) == dec("140"))
        #expect(book.convert(dec("100"), from: .usd, to: .aud, on: day(200)) == dec("155"))
    }

    @Test("Converted balance of a foreign-currency account")
    func convertedCurrencyBalance() {
        let book = Book(baseCurrency: .aud)
        let usdCash = Account(name: "US Cash", type: .bank, commodity: .usd)
        book.addAccount(usdCash)
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(0))

        let txn = Transaction(currency: .usd, datePosted: day(1), description: "Deposit")
        txn.addSplit(account: usdCash, value: dec("200"))
        txn.addSplit(account: book.rootAccount, value: dec("-200"))
        book.addTransaction(txn)

        #expect(book.balance(of: usdCash).amount == dec("200"))
        #expect(book.convertedBalance(of: usdCash, in: .aud, on: day(10)) == dec("300"))
    }

    @Test("Foreign security valued via its quote currency and FX")
    func foreignSecurity() {
        let book = Book(baseCurrency: .aud)
        let apple = Commodity(namespace: .security("NASDAQ"), mnemonic: "AAPL",
                              fullName: "Apple", smallestFraction: 10000)
        let holding = Account(name: "AAPL", type: .stock, commodity: apple)
        book.addAccount(holding)
        // Price in USD, plus a USD→AUD rate. No direct AAPL→AUD price.
        book.addPrice(Price(commodity: apple, currency: .usd, date: day(0), value: dec("200")))
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(0))

        #expect(book.securityUnitValue(apple, in: .usd) == dec("200"))
        #expect(book.securityUnitValue(apple, in: .aud) == dec("300"))

        let buy = Transaction(currency: .usd, datePosted: day(1), description: "Buy 10")
        buy.addSplit(account: holding, value: dec("2000"), quantity: dec("10"))
        buy.addSplit(account: book.rootAccount, value: dec("-2000"))
        book.addTransaction(buy)
        // 10 shares × (200 USD × 1.50) = 3000 AUD.
        #expect(book.convertedBalance(of: holding, in: .aud, on: day(10)) == dec("3000"))
    }
}
