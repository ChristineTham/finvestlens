//
//  PriceTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Price database")
struct PriceTests {

    private let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                                fullName: "Commonwealth Bank", smallestFraction: 10000)

    @Test("Latest price on or before a date")
    func latestPrice() {
        let book = Book(baseCurrency: .aud)
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 1, 1), value: dec("100")))
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 2, 1), value: dec("110")))
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 3, 1), value: dec("105")))

        #expect(book.latestPrice(of: cba, in: .aud, on: day(2026, 2, 15))?.value == dec("110"))
        #expect(book.latestPrice(of: cba, in: .aud)?.value == dec("105"))          // overall latest
        #expect(book.latestPrice(of: cba, in: .aud, on: day(2025, 12, 1)) == nil)  // before any price
    }

    @Test("Valuation multiplies quantity by price")
    func valuation() {
        let book = Book(baseCurrency: .aud)
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 2, 1), value: dec("110")))
        #expect(book.value(of: dec("10"), commodity: cba, in: .aud, on: day(2026, 3, 1)) == dec("1100"))
        // Same commodity → unchanged.
        #expect(book.value(of: dec("50"), commodity: .aud, in: .aud) == dec("50"))
        // No price for USD → nil.
        #expect(book.value(of: dec("10"), commodity: .usd, in: .aud) == nil)
    }

    @Test("Adding a price registers its commodities")
    func registersCommodities() {
        let book = Book(baseCurrency: .aud)
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 1, 1), value: dec("100")))
        #expect(book.commodities.contains(cba))
    }
}
