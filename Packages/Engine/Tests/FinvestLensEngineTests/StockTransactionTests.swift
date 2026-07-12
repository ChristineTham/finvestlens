//
//  StockTransactionTests.swift
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

@Suite("Stock transaction builder")
struct StockTransactionTests {

    private let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                                fullName: "Commonwealth Bank", smallestFraction: 10000)

    private func accounts() -> (stock: Account, cash: Account, fee: Account, income: Account) {
        (Account(name: "CBA", type: .stock, commodity: cba),
         Account(name: "Cash", type: .bank, commodity: .aud),
         Account(name: "Commission", type: .expense, commodity: .aud),
         Account(name: "Dividends", type: .income, commodity: .aud))
    }

    @Test("Buy balances and records shares and commission")
    func buy() {
        let a = accounts()
        let txn = StockTransaction.buy(
            security: a.stock, cash: a.cash, commissionAccount: a.fee,
            shares: dec("10"), pricePerShare: dec("10"), commission: dec("9.95"),
            date: day(0), currency: .aud, description: "Buy CBA")
        #expect(txn.isBalanced)
        let stockSplit = txn.splits.first { $0.account === a.stock }
        #expect(stockSplit?.value == dec("100"))
        #expect(stockSplit?.quantity == dec("10"))
        #expect(txn.splits.first { $0.account === a.cash }?.value == dec("-109.95"))
        #expect(txn.splits.first { $0.account === a.fee }?.value == dec("9.95"))
    }

    @Test("Buy without commission has two splits")
    func buyNoCommission() {
        let a = accounts()
        let txn = StockTransaction.buy(
            security: a.stock, cash: a.cash,
            shares: dec("5"), pricePerShare: dec("20"),
            date: day(0), currency: .aud, description: "Buy")
        #expect(txn.isBalanced)
        #expect(txn.splits.count == 2)
    }

    @Test("Sell balances; proceeds gross, commission expensed")
    func sell() {
        let a = accounts()
        let txn = StockTransaction.sell(
            security: a.stock, cash: a.cash, commissionAccount: a.fee,
            shares: dec("5"), pricePerShare: dec("15"), commission: dec("9.95"),
            date: day(400), currency: .aud, description: "Sell CBA")
        #expect(txn.isBalanced)
        let stockSplit = txn.splits.first { $0.account === a.stock }
        #expect(stockSplit?.value == dec("-75"))   // gross proceeds
        #expect(stockSplit?.quantity == dec("-5"))
        #expect(txn.splits.first { $0.account === a.cash }?.value == dec("65.05")) // net of fee
    }

    @Test("Cash dividend credits income and debits cash")
    func dividend() {
        let a = accounts()
        let txn = StockTransaction.dividend(
            income: a.income, cash: a.cash, amount: dec("42.50"),
            date: day(30), currency: .aud, description: "CBA dividend")
        #expect(txn.isBalanced)
        #expect(txn.splits.first { $0.account === a.income }?.value == dec("-42.50"))
        #expect(txn.splits.first { $0.account === a.cash }?.value == dec("42.50"))
    }

    @Test("Reinvested dividend adds shares at cost = amount")
    func reinvest() {
        let a = accounts()
        let txn = StockTransaction.reinvestDividend(
            income: a.income, security: a.stock, shares: dec("2.5"), amount: dec("42.50"),
            date: day(30), currency: .aud, description: "DRP")
        #expect(txn.isBalanced)
        let stockSplit = txn.splits.first { $0.account === a.stock }
        #expect(stockSplit?.value == dec("42.50"))
        #expect(stockSplit?.quantity == dec("2.5"))
    }

    @Test("Buy then sell flows through cost basis")
    func costBasisFlow() {
        let a = accounts()
        let book = Book(baseCurrency: .aud)
        book.addAccount(a.stock); book.addAccount(a.cash); book.addAccount(a.fee)
        book.addTransaction(StockTransaction.buy(
            security: a.stock, cash: a.cash, commissionAccount: a.fee,
            shares: dec("10"), pricePerShare: dec("10"), commission: dec("10"),
            date: day(0), currency: .aud, description: "Buy"))
        book.addTransaction(StockTransaction.sell(
            security: a.stock, cash: a.cash,
            shares: dec("10"), pricePerShare: dec("15"),
            date: day(400), currency: .aud, description: "Sell"))
        let result = book.costBasis(for: a.stock, method: .fifo)
        // Commission is expensed separately (not capitalised), so the basis is
        // the principal only: 10 × $10 = $100. Gain = proceeds 150 − 100.
        #expect(result.remainingQuantity == 0)
        #expect(result.totalCostBasis == dec("100"))
        #expect(result.totalProceeds == dec("150"))
        #expect(result.totalRealizedGain == dec("50"))
        #expect(result.realizedGains.first?.longTerm == true)
    }
}
