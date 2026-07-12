//
//  CapitalGainsModelTests.swift
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
@Suite("Capital gains (AppModel)")
struct CapitalGainsModelTests {

    @Test("Method selection changes cost basis, gain reported")
    func methodSwitch() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let stockID = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
        let cashID = try #require(model.addAccount(name: "Cash", type: .bank))

        try model.addTransaction(date: day(0), description: "Buy 10 @ 10", currency: .aud, splits: [
            SplitInput(accountID: stockID, value: dec("100"), quantity: dec("10")),
            SplitInput(accountID: cashID, value: dec("-100")),
        ])
        try model.addTransaction(date: day(400), description: "Buy 10 @ 12", currency: .aud, splits: [
            SplitInput(accountID: stockID, value: dec("120"), quantity: dec("10")),
            SplitInput(accountID: cashID, value: dec("-120")),
        ])
        try model.addTransaction(date: day(800), description: "Sell 15 @ 15", currency: .aud, splits: [
            SplitInput(accountID: stockID, value: dec("-225"), quantity: dec("-15")),
            SplitInput(accountID: cashID, value: dec("225")),
        ])

        model.costBasisMethod = .fifo
        #expect(model.capitalGains()?.totalGain == dec("65"))

        model.costBasisMethod = .lifo
        #expect(model.capitalGains()?.totalGain == dec("55"))

        model.costBasisMethod = .average
        #expect(model.capitalGains()?.totalGain == dec("60"))
    }

    @Test("No securities yields no report")
    func noSecurities() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = model.addAccount(name: "Cash", type: .bank)
        #expect(model.capitalGains() == nil)
    }
}
