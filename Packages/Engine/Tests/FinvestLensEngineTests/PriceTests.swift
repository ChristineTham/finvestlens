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

/// The price index replaced a linear scan of the whole database. These pin the
/// replacement to the scan's exact answers — including ties, where picking a
/// different duplicate would silently move a balance.
@Suite("Price index equivalence")
struct PriceIndexEquivalenceTests {

    /// The linear scan `latestPrice` used to be, kept here as the oracle.
    private func scan(_ book: Book, _ commodity: Commodity, _ currency: Commodity,
                      _ date: Date?) -> Price? {
        var best: Price?
        for price in book.prices {
            guard price.commodity == commodity, price.currency == currency else { continue }
            if let date, price.date > date { continue }
            if best == nil || price.date > best!.date { best = price }
        }
        return best
    }

    private func scanAny(_ book: Book, _ commodity: Commodity, _ date: Date?) -> Price? {
        var best: Price?
        for price in book.prices {
            guard price.commodity == commodity else { continue }
            if let date, price.date > date { continue }
            if best == nil || price.date > best!.date { best = price }
        }
        return best
    }

    private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }

    /// A book of pseudo-random prices with deliberate duplicate dates.
    private func book(seed: UInt64) -> (Book, [Commodity]) {
        var state = seed
        func next(_ bound: Int) -> Int {          // xorshift — deterministic
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(bound))
        }
        let b = Book(baseCurrency: .aud)
        let commodities = [
            Commodity(namespace: .security("ASX"), mnemonic: "AAA", fullName: "A", smallestFraction: 10000),
            Commodity(namespace: .security("ASX"), mnemonic: "BBB", fullName: "B", smallestFraction: 10000),
            Commodity.usd,
        ]
        for _ in 0..<400 {
            let c = commodities[next(commodities.count)]
            let cur = next(2) == 0 ? Commodity.aud : Commodity.usd
            guard c != cur else { continue }
            // Dates drawn from a small pool, so duplicates are common.
            b.addPrice(Price(commodity: c, currency: cur, date: day(next(20)),
                             value: Decimal(next(1000) + 1)))
        }
        return (b, commodities)
    }

    @Test("Indexed lookups match the linear scan, ties included")
    func matchesScan() {
        for seed in [UInt64(1), 42, 9_999] {
            let (b, commodities) = book(seed: seed)
            for c in commodities {
                for cur in [Commodity.aud, .usd] {
                    for d in [nil, day(-1), day(0), day(5), day(10), day(19), day(50)] as [Date?] {
                        let expected = scan(b, c, cur, d)
                        let actual = b.latestPrice(of: c, in: cur, on: d)
                        #expect(actual?.guid == expected?.guid,
                                "seed \(seed) \(c.mnemonic)/\(cur.mnemonic) on \(String(describing: d))")
                    }
                    _ = cur
                }
                for d in [nil, day(0), day(7), day(19)] as [Date?] {
                    #expect(b.latestPriceInAnyCurrency(of: c, on: d)?.guid == scanAny(b, c, d)?.guid)
                }
            }
        }
    }

    @Test("The index refreshes when the price database changes")
    func invalidation() {
        let b = Book(baseCurrency: .aud)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "CBA", smallestFraction: 10000)
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(1), value: 10))
        #expect(b.latestPrice(of: cba, in: .aud)?.value == 10)   // builds the index

        // Added after the index exists.
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(2), value: 20))
        #expect(b.latestPrice(of: cba, in: .aud)?.value == 20)

        // Removed after the index exists.
        let newest = b.prices.first { $0.value == 20 }!
        b.removePrice(newest.guid)
        #expect(b.latestPrice(of: cba, in: .aud)?.value == 10)

        // An unknown pair is nil, not a stale hit.
        #expect(b.latestPrice(of: cba, in: .usd) == nil)
    }
}
