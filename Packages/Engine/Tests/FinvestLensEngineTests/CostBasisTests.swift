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

    @Test("An uncovered oversale opens a short with no realised gain yet")
    func oversale() {
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("5"), value: dec("50")),
            LotEvent(date: day(10), quantity: dec("-8"), value: dec("-80")),
        ], method: .fifo)
        // 5 covered (bought and sold at $10 → gain 0). The 3 uncovered shares
        // are an open short: GnuCash records no gain until they're bought back.
        #expect(result.realizedGains.count == 1)
        #expect(result.totalCostBasis == dec("50"))
        #expect(result.totalProceeds == dec("50"))      // only the covered part
        #expect(result.totalRealizedGain == 0)
        #expect(result.shortQuantity == dec("3"))
        #expect(result.remainingQuantity == dec("-3"))
    }

    @Test("A buy after an oversale strikes the short's gain at the cover",
          arguments: [CostBasisMethod.fifo, .lifo, .average])
    func shortCover(method: CostBasisMethod) {
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("5"), value: dec("50")),
            LotEvent(date: day(10), quantity: dec("-8"), value: dec("-80")),
            LotEvent(date: day(20), quantity: dec("3"), value: dec("36")),
        ], method: method)
        // The buy-back closes the short instead of becoming a phantom holding.
        #expect(result.shortQuantity == 0)
        #expect(result.remainingQuantity == 0)
        #expect(result.openLots.isEmpty)
        // Economic truth: proceeds 80 − buys 86 = −6 realised overall.
        #expect(result.totalRealizedGain == dec("-6"))
        // GnuCash strikes one net gain on the covering buy: the 3 short shares'
        // proceeds (3 × $10 = 30) less the buy-back cost (36), dated at the buy.
        #expect(result.realizedGains.contains {
            $0.disposalDate == day(20) && $0.proceeds == dec("30") && $0.costBasis == dec("36")
        })
    }

    @Test("A pure short sale realises the gain only when covered, at the cover")
    func pureShortGainAtCover() {
        // Short 50 @ $600, cover 50 @ $500 later. GnuCash books one +$100 gain
        // dated at the cover — not +$600 at the sale and −$500 at the cover.
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("-50"), value: dec("-600")),
            LotEvent(date: day(30), quantity: dec("50"), value: dec("500")),
        ], method: .fifo)
        #expect(result.realizedGains.count == 1)
        let g = result.realizedGains[0]
        #expect(g.disposalDate == day(30))       // realised at the cover
        #expect(g.proceeds == dec("600"))
        #expect(g.costBasis == dec("500"))
        #expect(g.gain == dec("100"))
        #expect(result.shortQuantity == 0)
    }

    @Test("A buy larger than the short covers it and opens the remainder")
    func partialCover() {
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("5"), value: dec("50")),
            LotEvent(date: day(10), quantity: dec("-8"), value: dec("-80")),
            LotEvent(date: day(20), quantity: dec("10"), value: dec("120")),
        ], method: .fifo)
        // 3 of the 10 bought shares cover the short; 7 open at $12 each.
        #expect(result.shortQuantity == 0)
        #expect(result.remainingQuantity == dec("7"))
        #expect(result.remainingCostBasis == dec("84"))
        #expect(result.openLots.count == 1)
    }

    @Test("Include-in-basis folds a buy's fee into cost and a sale's fee into realised")
    func feeIncludeInBasis() {
        // Buy 10 @ $10 with a $5 fee (day 0); sell 4 @ $15 with a $2 fee (day 400).
        let events = [
            LotEvent(date: day(0), quantity: dec("10"), value: dec("100"), fee: dec("5")),
            LotEvent(date: day(400), quantity: dec("-4"), value: dec("-60"), fee: dec("2")),
        ]
        // Ignore: basis is the raw $10/share; 4 sold cost 40, 6 remain cost 60.
        let ignore = CostBasis.compute(events: events, method: .fifo, feeTreatment: .ignore)
        #expect(ignore.remainingCostBasis == dec("60"))
        #expect(ignore.totalRealizedGain == dec("20"))   // 60 − 40

        // Include: the $5 buy fee makes cost $10.50/share; 4 sold cost 42, plus
        // the $2 sale fee → realised cost 44; 6 remain cost 63.
        let include = CostBasis.compute(events: events, method: .fifo,
                                        feeTreatment: .includeInBasis)
        #expect(include.remainingCostBasis == dec("63"))
        #expect(include.totalCostBasis == dec("44"))      // 4 × 10.50 + 2
        #expect(include.totalRealizedGain == dec("16"))   // 60 − 44

        // Average cost folds fees the same way.
        let avg = CostBasis.compute(events: events, method: .average,
                                    feeTreatment: .includeInBasis)
        #expect(avg.totalRealizedGain == dec("16"))
        #expect(avg.remainingCostBasis == dec("63"))
    }

    @Test("Basis rounds to the currency fraction per disposal (GnuCash parity)")
    func basisRoundsToCents() {
        // Buy 7 @ $100, sell 3 @ $60. Per-share cost 100/7 = 14.2857…, so the
        // basis for 3 shares is 42.857… — GnuCash rounds it to $42.86.
        let ev = [
            LotEvent(date: day(0), quantity: dec("7"), value: dec("100")),
            LotEvent(date: day(10), quantity: dec("-3"), value: dec("-60")),
        ]
        let rounded = CostBasis.compute(events: ev, method: .fifo, currencyFraction: 100)
        #expect(rounded.totalCostBasis == dec("42.86"))
        #expect(rounded.totalProceeds == dec("60"))
        #expect(rounded.totalRealizedGain == dec("17.14"))
        // Without a fraction, full precision is kept (the old behaviour).
        let exact = CostBasis.compute(events: ev, method: .fifo)
        #expect(exact.totalCostBasis == dec("300") / dec("7"))
    }

    @Test("A multi-lot sale allocates proceeds to the cent, remainder in the last")
    func proceedsRemainderAbsorbed() {
        // Three 1-share lots, sell all 3 for $1.00. Cents can't divide evenly;
        // each parcel is cent-exact and the parcels sum back to exactly $1.00.
        let ev = [
            LotEvent(date: day(0), quantity: dec("1"), value: dec("5")),
            LotEvent(date: day(1), quantity: dec("1"), value: dec("5")),
            LotEvent(date: day(2), quantity: dec("1"), value: dec("5")),
            LotEvent(date: day(3), quantity: dec("-3"), value: dec("-1")),
        ]
        let r = CostBasis.compute(events: ev, method: .fifo, currencyFraction: 100)
        #expect(r.realizedGains.count == 3)
        #expect(r.totalProceeds == dec("1"))                      // exact, no drift
        for g in r.realizedGains { #expect(CostBasis.rounded(g.proceeds, 100) == g.proceeds) }
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
