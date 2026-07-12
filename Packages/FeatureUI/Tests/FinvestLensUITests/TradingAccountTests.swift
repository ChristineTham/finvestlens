//
//  TradingAccountTests.swift
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
private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }

@MainActor
@Suite("Trading accounts")
struct TradingAccountTests {

    @Test("Trading transfer balances per currency and keeps the sheet balanced")
    func balances() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let aud = try #require(model.addAccount(name: "AUD Cash", type: .bank, commodity: .aud))
        let usd = try #require(model.addAccount(name: "USD Cash", type: .bank, commodity: .usd))
        model.addExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(0))
        model.useTradingAccounts = true

        // 300 AUD out, 200 USD in (implied 1.5).
        try model.recordCurrencyTransfer(fromID: aud, toID: usd,
                                         sourceAmount: dec("300"), destAmount: dec("200"),
                                         date: day(1), description: "FX")

        let book = model.book!
        // The transaction has 4 legs and balances by value.
        let txn = book.transactions.first { $0.transactionDescription == "FX" }!
        #expect(txn.splits.count == 4)
        #expect(txn.isBalanced)

        // Each currency's quantities net to zero (trading offsets the cash legs).
        func currencyNet(_ commodity: Commodity) -> Decimal {
            txn.splits.filter { $0.account?.commodity == commodity }.reduce(Decimal(0)) { $0 + $1.quantity }
        }
        #expect(currencyNet(.aud) == 0)
        #expect(currencyNet(.usd) == 0)

        // At the implied rate the sheet balances exactly.
        let sheet = model.balanceSheet(asOf: day(10))!
        #expect(sheet.isBalanced)

        // After the AUD strengthens, the sheet still balances (unrealised FX in
        // equity absorbs the difference).
        model.addExchangeRate(from: .usd, to: .aud, rate: dec("1.60"), date: day(5))
        let sheet2 = model.balanceSheet(asOf: day(10))!
        #expect(sheet2.isBalanced)
    }
}
