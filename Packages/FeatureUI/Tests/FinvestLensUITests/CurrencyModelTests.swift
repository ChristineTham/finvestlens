//
//  CurrencyModelTests.swift
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
private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }

@MainActor
@Suite("Multi-currency (AppModel)")
struct CurrencyModelTests {

    private func model() throws -> (AppModel, GncGUID, GncGUID, URL) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let aud = try #require(model.addAccount(name: "AUD Bank", type: .bank, commodity: .aud))
        let usd = try #require(model.addAccount(name: "USD Bank", type: .bank, commodity: .usd))
        return (model, aud, usd, url)
    }

    @Test("Currency list reflects account commodities")
    func currencies() throws {
        let (model, _, _, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let codes = model.currencyCommodities.map(\.mnemonic)
        #expect(codes.contains("AUD"))
        #expect(codes.contains("USD"))
    }

    @Test("Currency transfer balances and records a rate/rate row")
    func transfer() throws {
        let (model, aud, usd, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        // Move 300 AUD out, 200 USD in (rate AUD→USD = 0.6667).
        try model.recordCurrencyTransfer(fromID: aud, toID: usd,
                                         sourceAmount: dec("300"), destAmount: dec("200"),
                                         date: day(0), description: "FX")

        // Native balances reflect the two currencies.
        model.selectedAccountID = usd
        #expect(model.registerRows.last?.description == "FX")
        // A rate row now exists AUD→USD.
        #expect(model.rateRows.contains { $0.from == "AUD" && $0.to == "USD" && $0.value == dec("200") / dec("300") })
    }

    @Test("Added rate values a foreign balance sheet")
    func rateValuation() throws {
        let (model, _, usd, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let opening = try #require(model.addAccount(name: "USD Opening", type: .equity, commodity: .usd))
        // Deposit 200 USD from a USD-denominated equity account.
        try model.addTransaction(date: day(1), description: "USD in", currency: .usd, splits: [
            SplitInput(accountID: usd, value: dec("200")),
            SplitInput(accountID: opening, value: dec("-200")),
        ])
        model.addExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(0))
        #expect(model.rateRows.contains { $0.from == "USD" && $0.to == "AUD" })

        let sheet = model.balanceSheet(asOf: day(10))
        #expect(sheet?.assets.contains { $0.name == "USD Bank" && $0.amount == dec("300") } == true)
    }

    @Test("Same-currency transfer throws")
    func sameCurrency() throws {
        let (model, aud, _, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let aud2 = try #require(model.addAccount(name: "AUD Savings", type: .bank, commodity: .aud))
        #expect(throws: CurrencyEntryError.sameCurrency) {
            try model.recordCurrencyTransfer(fromID: aud, toID: aud2,
                                             sourceAmount: dec("100"), destAmount: dec("100"),
                                             date: day(0), description: "x")
        }
    }
}
