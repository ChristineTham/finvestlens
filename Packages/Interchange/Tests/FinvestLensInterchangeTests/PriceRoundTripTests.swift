//
//  PriceRoundTripTests.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensInterchange

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Price round-trip")
struct PriceRoundTripTests {

    private func bookWithPrice() -> (Book, GncGUID) {
        let book = Book(baseCurrency: .aud)
        book.addAccount(Account(name: "Root Account", type: .root, commodity: .aud))
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let price = Price(commodity: cba, currency: .aud, date: day(2026, 2, 1), value: dec("105.20"))
        book.addPrice(price)
        return (book, price.guid)
    }

    @Test("Prices survive export → import")
    func roundTrip() throws {
        let (book, priceGUID) = bookWithPrice()
        let data = GnuCashXMLExporter.export(book)
        let result = try GnuCashXMLImporter.importBook(from: data)

        #expect(result.summary.priceCount == 1)
        let price = try #require(result.book.prices.first)
        #expect(price.guid == priceGUID)
        #expect(price.commodity.mnemonic == "CBA")
        #expect(price.commodity.namespace == .security("ASX"))
        #expect(price.currency == .aud)
        #expect(price.value == dec("105.20"))
        #expect(result.book.latestPrice(of: price.commodity, in: .aud)?.value == dec("105.20"))
    }

    @Test("Exported XML contains a price database")
    func exportedContents() {
        let (book, _) = bookWithPrice()
        let xml = String(decoding: GnuCashXMLExporter.export(book), as: UTF8.self)
        #expect(xml.contains("<gnc:pricedb"))
        #expect(xml.contains("<price:value>"))
        #expect(xml.contains("<cmdty:id>CBA</cmdty:id>"))
    }
}
