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

    @Test("Nearest-in-time can pick a later price (GnuCash pricedb-nearest)")
    func nearestInTime() {
        let book = Book(baseCurrency: .aud)
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.40"), date: day(0))
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.60"), date: day(100))
        // day 70: the day-100 price is 30 days away, day-0 is 70 — the later
        // price is nearer, so GnuCash's default source uses it.
        #expect(book.exchangeRate(from: .usd, to: .aud, on: day(70)) == dec("1.60"))
        // day 40: day-0 is nearer (40 vs 60).
        #expect(book.exchangeRate(from: .usd, to: .aud, on: day(40)) == dec("1.40"))
        // Equal distance (day 50) → the earlier price, matching GnuCash's tie rule.
        #expect(book.exchangeRate(from: .usd, to: .aud, on: day(50)) == dec("1.40"))
    }

    @Test("Indirect conversion chains through a common currency")
    func indirectChaining() {
        let book = Book(baseCurrency: .aud)
        // AUD→EUR and USD→EUR exist; AUD↔USD does not.
        book.setExchangeRate(from: .aud, to: .eur, rate: dec("0.60"), date: day(0))
        book.setExchangeRate(from: .usd, to: .eur, rate: dec("0.90"), date: day(0))
        // AUD→USD via EUR: 0.60 × (1 / 0.90).
        let rate = try! #require(book.exchangeRate(from: .aud, to: .usd))
        #expect(rate == dec("0.60") / dec("0.90"))
    }
}

@Suite("Book FX gaps")
struct BookFXGapTests {

    private let gbp = Commodity.currency("GBP", name: "Pound Sterling")

    private func stock(_ mnemonic: String) -> Commodity {
        Commodity(namespace: .security("LSE"), mnemonic: mnemonic,
                  fullName: mnemonic, smallestFraction: 10000)
    }

    @Test("convert returns nil when no rate path exists")
    func convertNil() {
        let book = Book(baseCurrency: .aud)
        #expect(book.convert(dec("100"), from: .eur, to: .aud) == nil)
        #expect(book.exchangeRate(from: .eur, to: .aud) == nil)
    }

    @Test("Security valuation skips quote currencies with no FX path")
    func quoteCurrencySkipping() {
        let book = Book(baseCurrency: .aud)
        let tst = stock("TST")
        // Priced in EUR (no EUR→AUD rate) and in GBP (with a GBP→AUD rate).
        book.addPrice(Price(commodity: tst, currency: .eur, date: day(0), value: dec("90")))
        book.addPrice(Price(commodity: tst, currency: gbp, date: day(0), value: dec("100")))
        book.setExchangeRate(from: gbp, to: .aud, rate: dec("2"), date: day(0))
        // EUR sorts first and dead-ends; GBP carries the valuation.
        #expect(book.securityUnitValue(tst, in: .aud) == dec("200"))
    }

    @Test("Security valuation is nil when no quote currency reaches the target")
    func unreachableSecurity() {
        let book = Book(baseCurrency: .aud)
        let tst = stock("TST")
        book.addPrice(Price(commodity: tst, currency: .eur, date: day(0), value: dec("90")))
        #expect(book.securityUnitValue(tst, in: .aud) == nil)
        // And with no prices at all.
        #expect(book.securityUnitValue(stock("NIL"), in: .aud) == nil)
    }

    @Test("Latest price in any currency picks by date, not by currency")
    func latestAnyCurrency() {
        let book = Book(baseCurrency: .aud)
        let tst = stock("TST")
        book.addPrice(Price(commodity: tst, currency: .eur, date: day(0), value: dec("90")))
        book.addPrice(Price(commodity: tst, currency: gbp, date: day(5), value: dec("100")))
        #expect(book.latestPriceInAnyCurrency(of: tst)?.currency == gbp)
        #expect(book.latestPriceInAnyCurrency(of: tst, on: day(2))?.currency == .eur)
        #expect(book.latestPriceInAnyCurrency(of: .usd) == nil)
    }

    @Test("Subtree conversion values each account in its own commodity")
    func subtreeConversion() {
        let book = Book(baseCurrency: .aud)
        let parent = book.addAccount(Account(name: "Investments", type: .asset, commodity: .aud))
        let audCash = book.addAccount(Account(name: "AUD Cash", type: .bank, commodity: .aud),
                                      under: parent)
        let usdCash = book.addAccount(Account(name: "USD Cash", type: .bank, commodity: .usd),
                                      under: parent)
        let eurCash = book.addAccount(Account(name: "EUR Cash", type: .bank, commodity: .eur),
                                      under: parent)
        let apple = Commodity(namespace: .security("NASDAQ"), mnemonic: "AAPL",
                              fullName: "Apple", smallestFraction: 10000)
        let holding = book.addAccount(Account(name: "AAPL", type: .stock, commodity: apple),
                                      under: parent)

        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(0))
        book.addPrice(Price(commodity: apple, currency: .usd, date: day(0), value: dec("200")))

        func deposit(_ amount: String, into account: Account, currency: Commodity,
                     quantity: String? = nil) {
            let txn = Transaction(currency: currency, datePosted: day(1), description: "Deposit")
            txn.addSplit(account: account, value: dec(amount), quantity: quantity.map { dec($0) })
            txn.addSplit(account: book.rootAccount, value: -dec(amount))
            book.addTransaction(txn)
        }
        deposit("100", into: audCash, currency: .aud)
        deposit("200", into: usdCash, currency: .usd)
        deposit("2000", into: holding, currency: .usd, quantity: "10")
        // EUR account left at zero: no rate exists, and none is needed.

        // 100 + 200×1.5 + 10×(200×1.5) = 3,400.
        #expect(book.convertedBalance(of: parent, in: .aud, on: day(2),
                                      includingDescendants: true) == dec("3400"))

        // Same-commodity accounts answer natively; a rateless one answers nil
        // even at zero balance — only the subtree walk skips zero balances.
        #expect(book.convertedBalance(of: audCash, in: .aud, on: day(2)) == dec("100"))
        #expect(book.convertedBalance(of: eurCash, in: .aud, on: day(2)) == nil)

        // A non-zero balance in an unpriceable commodity poisons the subtree.
        deposit("50", into: eurCash, currency: .eur)
        #expect(book.convertedBalance(of: parent, in: .aud, on: day(2),
                                      includingDescendants: true) == nil)
        #expect(book.convertedBalance(of: eurCash, in: .aud, on: day(2)) == nil)
    }
}
