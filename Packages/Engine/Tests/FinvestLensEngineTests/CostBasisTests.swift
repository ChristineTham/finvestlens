//
//  CostBasisTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
/// A date `days` after the epoch, for deterministic holding-period tests.
private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }

@Suite("Cost basis")
struct CostBasisTests {

    // Buy 10 @ $10 (day 0), buy 10 @ $12 (day 400), sell 15 @ $15 (day 800).
    private let events: [LotEvent] = [
        LotEvent(date: day(0), quantity: dec("10"), value: dec("100")),
        LotEvent(date: day(400), quantity: dec("10"), value: dec("120")),
        LotEvent(date: day(800), quantity: dec("-15"), value: dec("-225")),
    ]

    @Test("FIFO sells the oldest lot first")
    func fifo() {
        let result = CostBasis.compute(events: events, method: .fifo)
        // 10 from the $10 lot + 5 from the $12 lot = 100 + 60 = 160 cost basis.
        #expect(result.totalCostBasis == dec("160"))
        #expect(result.totalProceeds == dec("225"))
        #expect(result.totalRealizedGain == dec("65"))
        // 5 shares remain from the $12 lot → cost basis 60.
        #expect(result.remainingQuantity == dec("5"))
        #expect(result.remainingCostBasis == dec("60"))
        #expect(result.realizedGains.count == 2)
    }

    @Test("LIFO sells the newest lot first")
    func lifo() {
        let result = CostBasis.compute(events: events, method: .lifo)
        // 10 from the $12 lot + 5 from the $10 lot = 120 + 50 = 170 cost basis.
        #expect(result.totalCostBasis == dec("170"))
        #expect(result.totalRealizedGain == dec("55"))
        #expect(result.remainingQuantity == dec("5"))
        #expect(result.remainingCostBasis == dec("50"))
    }

    @Test("Average cost pools all shares")
    func average() {
        let result = CostBasis.compute(events: events, method: .average)
        // Pool: 20 shares, $220 → $11/share. 15 sold → 165 cost basis.
        #expect(result.totalCostBasis == dec("165"))
        #expect(result.totalRealizedGain == dec("60"))
        #expect(result.remainingQuantity == dec("5"))
        #expect(result.remainingCostBasis == dec("55"))
        #expect(result.realizedGains.count == 1)
    }

    @Test("Holding period splits short vs long term (FIFO)")
    func holdingPeriod() {
        let result = CostBasis.compute(events: events, method: .fifo)
        // First parcel: day 0 → day 800 (800 days) is long term.
        // Second parcel: day 400 → day 800 (400 days) is also long term here.
        #expect(result.realizedGains.allSatisfy { $0.longTerm == true })

        // A quick sale is short term.
        let quick = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("10"), value: dec("100")),
            LotEvent(date: day(30), quantity: dec("-10"), value: dec("-150")),
        ], method: .fifo)
        #expect(quick.realizedGains.first?.longTerm == false)
        #expect(quick.realizedGains.first?.holdingDays == 30)
    }

    @Test("A loss is a negative gain")
    func loss() {
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("10"), value: dec("100")),
            LotEvent(date: day(10), quantity: dec("-10"), value: dec("-70")),
        ], method: .fifo)
        #expect(result.totalRealizedGain == dec("-30"))
    }

    @Test("Uncovered oversale gets zero cost basis")
    func oversale() {
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("5"), value: dec("50")),
            LotEvent(date: day(10), quantity: dec("-8"), value: dec("-80")),
        ], method: .fifo)
        // 5 covered (cost 50), 3 uncovered (cost 0). Proceeds 80.
        #expect(result.totalCostBasis == dec("50"))
        #expect(result.totalProceeds == dec("80"))
        #expect(result.realizedGains.contains { $0.acquisitionDate == nil && $0.costBasis == 0 })
        #expect(result.remainingQuantity == 0)
    }

    @Test("No disposals leaves every lot open")
    func noDisposals() {
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("10"), value: dec("100")),
            LotEvent(date: day(5), quantity: dec("10"), value: dec("120")),
        ], method: .fifo)
        #expect(result.realizedGains.isEmpty)
        #expect(result.remainingQuantity == dec("20"))
        #expect(result.remainingCostBasis == dec("220"))
        #expect(result.openLots.count == 2)
    }

    @Test("Book cost basis reads a security account's splits")
    func bookIntegration() {
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let book = Book(baseCurrency: .aud)
        let stock = Account(name: "CBA", type: .stock, commodity: cba)
        let cash = Account(name: "Cash", type: .bank, commodity: .aud)
        book.addAccount(stock); book.addAccount(cash)

        let buy = Transaction(currency: .aud, datePosted: day(0), description: "Buy")
        buy.addSplit(account: stock, value: dec("100"), quantity: dec("10"))
        buy.addSplit(account: cash, value: dec("-100"))
        book.addTransaction(buy)

        let sell = Transaction(currency: .aud, datePosted: day(400), description: "Sell")
        sell.addSplit(account: stock, value: dec("-75"), quantity: dec("-5"))
        sell.addSplit(account: cash, value: dec("75"))
        book.addTransaction(sell)

        let result = book.costBasis(for: stock, method: .fifo)
        #expect(result.remainingQuantity == dec("5"))
        #expect(result.totalRealizedGain == dec("25")) // proceeds 75 − cost 50
        #expect(result.realizedGains.first?.longTerm == true)
    }
}
