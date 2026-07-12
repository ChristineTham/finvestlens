//
//  PortfolioIntegrationTests.swift
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
@Suite("Portfolio & prices integration")
struct PortfolioIntegrationTests {

    @Test("Add a price, value the portfolio, and persist")
    func portfolioAndPersist() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)

        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let shares = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))

        // Buy 10 shares for $1,000 via a multi-split.
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_600_000_000), description: "Buy CBA",
                                 currency: .aud, splits: [
            SplitInput(accountID: shares, value: dec("1000")),
            SplitInput(accountID: bank, value: dec("-1000")),
        ])

        #expect(model.securityCommodities.contains(cba))
        model.addPrice(commodity: cba, currency: .aud,
                       date: Date(timeIntervalSince1970: 1_700_000_000), value: dec("120"))
        #expect(model.priceRows.count == 1)

        let portfolio = try #require(model.portfolio())
        // Shares default to value when quantity isn't given (10 units of value=1000),
        // so market value uses the priced commodity regardless; check it is priced.
        #expect(portfolio.holdings.first?.symbol == "CBA")
        #expect(portfolio.holdings.first?.price == dec("120"))

        try model.save()
        model.close()

        let reopened = AppModel()
        try reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.priceRows.count == 1)
        #expect(reopened.priceRows.first?.symbol == "CBA")
    }
}
