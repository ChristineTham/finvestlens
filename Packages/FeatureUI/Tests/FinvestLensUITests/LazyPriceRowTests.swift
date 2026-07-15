//
//  LazyPriceRowTests.swift
//  FinvestLens — FeatureUI
//
//  ``AppModel/priceRows`` and ``AppModel/rateRows`` are derived on demand and
//  cached (Architecture §12.6). The cache hangs off `refreshAll()`/`close()`,
//  which is what these tests pin: a cache that outlives its data would show the
//  user stale prices, which is worse than the sort it saves.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@MainActor
@Suite("Lazy price rows")
struct LazyPriceRowTests {

    /// A security priced twice: reading the rows, then adding a price, must not
    /// serve the first read's cache.
    @Test("Price rows refresh after a later edit")
    func cacheIsDroppedOnEdit() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "CBA", smallestFraction: 10_000)
        model.addPrice(commodity: cba, currency: .aud,
                       date: Date(timeIntervalSince1970: 1_700_000_000), value: dec("100.00"))

        // Populate the cache.
        #expect(model.priceRows.count == 1)

        // A second price must appear — if the cache survived the edit, it won't.
        model.addPrice(commodity: cba, currency: .aud,
                       date: Date(timeIntervalSince1970: 1_700_086_400), value: dec("101.00"))
        #expect(model.priceRows.count == 2)

        // Newest first, as the editor presents them.
        #expect(model.priceRows.first?.value == dec("101.00"))

        // …and a deletion is reflected too.
        let id = try #require(model.priceRows.first?.id)
        model.deletePrice(id)
        #expect(model.priceRows.count == 1)
        #expect(model.priceRows.first?.value == dec("100.00"))
    }

    /// Closing a book must not leave the previous book's prices on screen.
    @Test("Closing a book clears the rows")
    func cacheIsDroppedOnClose() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)

        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "CBA", smallestFraction: 10_000)
        model.addPrice(commodity: cba, currency: .aud,
                       date: Date(timeIntervalSince1970: 1_700_000_000), value: dec("100.00"))
        #expect(model.priceRows.count == 1)

        model.close()
        #expect(model.priceRows.isEmpty)
        #expect(model.rateRows.isEmpty)
    }
}
