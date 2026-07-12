//
//  SecuritiesTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Securities & watch list")
struct SecuritiesTests {

    @Test("Rename updates the name across accounts and prices, keeps identity")
    func rename() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth", smallestFraction: 10000)
        _ = model.addAccount(name: "CBA", type: .stock, commodity: cba)
        model.addPrice(commodity: cba, currency: .aud, date: Date(timeIntervalSince1970: 0), value: dec("100"))

        model.renameSecurity(cba, fullName: "Commonwealth Bank of Australia")
        let acct = model.book!.accounts.first { $0.commodity == cba }
        #expect(acct?.commodity.fullName == "Commonwealth Bank of Australia")
        // Identity preserved → the price still resolves.
        #expect(model.book!.latestPrice(of: cba, in: .aud)?.value == dec("100"))
    }

    @Test("Watch list adds a pricable, unheld security and persists")
    func watchlist() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)

        model.addWatchSecurity(exchange: "NASDAQ", ticker: "aapl", name: "Apple")
        #expect(model.watchlist.count == 1)
        let aapl = model.watchlist.first!
        #expect(aapl.mnemonic == "AAPL")
        #expect(model.pricableSecurities.contains(aapl))
        #expect(model.isWatchOnly(aapl))

        try model.save(); model.close()
        let reopened = AppModel()
        try reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.watchlist.first?.mnemonic == "AAPL")
    }
}
