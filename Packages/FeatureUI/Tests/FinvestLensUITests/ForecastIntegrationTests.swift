//
//  ForecastIntegrationTests.swift
//  FinvestLens — FeatureUI
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

@MainActor
@Suite("Cash-flow forecast integration")
struct ForecastIntegrationTests {

    @Test("Forecast projects the default account from scheduled transactions")
    func forecast() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let rent = try #require(model.addAccount(name: "Rent", type: .expense))

        // $1,000 opening balance yesterday.
        model.addTransfer(from: salary, to: bank, amount: Decimal(1000),
                          date: Date(timeIntervalSinceNow: -86_400), description: "Opening")

        // Monthly rent starting next week.
        model.addScheduledTransaction(ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: Date(timeIntervalSinceNow: 7 * 86_400)),
            splits: [
                ScheduledSplit(accountGUID: rent, value: Decimal(800)),
                ScheduledSplit(accountGUID: bank, value: Decimal(-800)),
            ]
        ))

        #expect(model.defaultForecastAccountID == bank)
        let points = model.cashFlowForecast(accountID: bank, months: 3)
        #expect(points.first?.balance == Decimal(1000))     // today
        #expect(points.count >= 2)                          // at least one rent occurrence
        #expect(points.contains { $0.change == Decimal(-800) })
    }
}
