//
//  PricePersistenceTests.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensPersistence

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Price persistence")
struct PricePersistenceTests {

    @Test("Prices survive a store round-trip")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }

        let book = Book(baseCurrency: .aud)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let price = Price(commodity: cba, currency: .aud,
                          date: Date(timeIntervalSince1970: 1_700_000_000), value: dec("105.20"))
        book.addPrice(price)
        try SQLiteDocumentStore(path: url.path).write(book)

        let reloaded = try SQLiteDocumentStore(path: url.path).read()
        let restored = try #require(reloaded.prices.first)
        #expect(restored.guid == price.guid)
        #expect(restored.commodity.mnemonic == "CBA")
        #expect(restored.commodity.namespace == .security("ASX"))
        #expect(restored.value == dec("105.20"))
        #expect(reloaded.latestPrice(of: cba, in: .aud)?.value == dec("105.20"))
    }
}
