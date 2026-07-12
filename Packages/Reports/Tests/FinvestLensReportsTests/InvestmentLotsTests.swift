//
//  InvestmentLotsTests.swift
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

@Suite("Investment lots report")
struct InvestmentLotsTests {

    @Test("One open lot per acquisition, valued at the latest price")
    func lots() {
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA", fullName: "CBA", smallestFraction: 10000)
        let book = Book(baseCurrency: .aud)
        let stock = Account(name: "CBA", type: .stock, commodity: cba)
        book.addAccount(stock)
        // Two buys → two lots.
        let b1 = Transaction(currency: .aud, datePosted: day(0), description: "Buy 1")
        b1.addSplit(account: stock, value: dec("100"), quantity: dec("10"))
        b1.addSplit(account: book.rootAccount, value: dec("-100"))
        book.addTransaction(b1)
        let b2 = Transaction(currency: .aud, datePosted: day(30), description: "Buy 2")
        b2.addSplit(account: stock, value: dec("120"), quantity: dec("10"))
        b2.addSplit(account: book.rootAccount, value: dec("-120"))
        book.addTransaction(b2)
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(40), value: dec("15")))

        let lots = FinancialReports.investmentLots(book, currency: .aud, asOf: day(50))
        #expect(lots.count == 2)
        // First lot: 10 @ $10 cost = $100, value 10 × $15 = $150, gain $50.
        #expect(lots.first?.costBasis == dec("100"))
        #expect(lots.first?.marketValue == dec("150"))
        #expect(lots.first?.unrealizedGain == dec("50"))
        #expect(lots.first?.holdingDays == 50)
    }

    @Test("A sale removes a consumed lot (FIFO)")
    func afterSale() {
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA", fullName: "CBA", smallestFraction: 10000)
        let book = Book(baseCurrency: .aud)
        let stock = Account(name: "CBA", type: .stock, commodity: cba)
        book.addAccount(stock)
        let b1 = Transaction(currency: .aud, datePosted: day(0), description: "Buy")
        b1.addSplit(account: stock, value: dec("100"), quantity: dec("10"))
        b1.addSplit(account: book.rootAccount, value: dec("-100"))
        book.addTransaction(b1)
        let sell = Transaction(currency: .aud, datePosted: day(30), description: "Sell all")
        sell.addSplit(account: stock, value: dec("-150"), quantity: dec("-10"))
        sell.addSplit(account: book.rootAccount, value: dec("150"))
        book.addTransaction(sell)

        let lots = FinancialReports.investmentLots(book, currency: .aud, asOf: day(50))
        #expect(lots.isEmpty)
    }
}
