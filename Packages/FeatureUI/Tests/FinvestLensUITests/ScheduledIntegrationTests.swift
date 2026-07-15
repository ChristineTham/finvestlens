//
//  ScheduledIntegrationTests.swift
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
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

@MainActor
@Suite("Scheduled transactions integration")
struct ScheduledIntegrationTests {

    private func setup() throws -> (AppModel, from: GncGUID, to: GncGUID, URL) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let rent = try #require(model.addAccount(name: "Rent", type: .expense))
        return (model, bank, rent, url)
    }

    private func rentSX(from: GncGUID, to: GncGUID) -> ScheduledTransaction {
        ScheduledTransaction(
            name: "Rent", currency: .aud, description: "Monthly rent",
            recurrence: Recurrence(period: .monthly, startDate: date(2020, 1, 1)),
            splits: [
                ScheduledSplit(accountGUID: to, value: Decimal(500)),
                ScheduledSplit(accountGUID: from, value: Decimal(-500)),
            ]
        )
    }

    @Test("Posting due instances creates transactions and advances lastPosted")
    func postDue() throws {
        let (model, from, to, url) = try setup()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.addScheduledTransaction(rentSX(from: from, to: to))
        let pending = model.pendingScheduled(through: date(2020, 3, 15))
        #expect(pending.count == 3)                     // Jan, Feb, Mar 2020

        let created = model.postDueScheduled(through: date(2020, 3, 15))
        #expect(created == 3)

        // Rent account now has 3 × $500.
        model.selectedAccountID = to
        #expect(model.registerRows.count == 3)

        // Nothing pending again through the same date (lastPosted advanced).
        #expect(model.pendingScheduled(through: date(2020, 3, 15)).isEmpty)
    }

    @Test("Scheduled transactions persist across save and reopen")
    func persist() async throws {
        let (model, from, to, url) = try setup()
        model.addScheduledTransaction(rentSX(from: from, to: to))
        try model.save()
        model.close()

        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.scheduledTransactions.first?.name == "Rent")
        #expect(reopened.scheduledTransactions.first?.isBalanced == true)
    }
}
