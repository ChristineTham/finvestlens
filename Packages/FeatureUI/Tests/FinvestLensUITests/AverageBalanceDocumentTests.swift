//
//  AverageBalanceDocumentTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Average balance (document wiring)")
struct AverageBalanceDocumentTests {

    /// Drives the whole production path — `reportDocument(for:)` → model method
    /// → engine — so a broken configuration, scope, or chart case shows up here
    /// rather than only in the GUI.
    @Test("The builder produces a document with a chart and one row per interval")
    func buildsDocument() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bankID = try #require(model.addAccount(name: "Everyday", type: .bank))
        let incomeID = try #require(model.addAccount(name: "Salary", type: .income))
        func post(_ iso: String, _ amount: String) throws {
            let parts = iso.split(separator: "-").map { Int($0)! }
            let date = calendar.date(from: DateComponents(
                year: parts[0], month: parts[1], day: parts[2], hour: 12))!
            try model.addTransaction(date: date, description: iso, currency: .aud, splits: [
                SplitInput(accountID: bankID, value: dec(amount), quantity: dec(amount)),
                SplitInput(accountID: incomeID, value: -dec(amount)),
            ])
        }
        // Two deposits in October, one withdrawal in November.
        try post("2025-10-03", "100")
        try post("2025-10-17", "100")
        try post("2025-11-05", "-50")

        let from = calendar.date(from: DateComponents(year: 2025, month: 10, day: 1))!
        let to = calendar.date(from: DateComponents(year: 2025, month: 11, day: 30))!
        let config = ReportConfiguration(
            kind: ReportKind.averageBalance.rawValue,
            period: .custom(from: from, to: to),
            accountIDs: [bankID], step: .month)

        let document = try #require(model.reportDocument(for: config))
        #expect(document.title == "Average Balance")
        #expect(document.kpis.contains { $0.label == "Average balance" })
        #expect(document.kpis.contains { $0.label == "Total in" && $0.amount == dec("200") })
        #expect(document.kpis.contains { $0.label == "Total out" && $0.amount == dec("50") })

        // Two monthly intervals → chart with two bars and a two-row table.
        guard case .averageBars(let intervals)? = document.chart else {
            Issue.record("expected an averageBars chart"); return
        }
        #expect(intervals.count == 2)
        #expect(document.sections.first?.rows.count == 2)
        // Every average sits within its own min/max range, and is positive here.
        #expect(intervals.allSatisfy { $0.average > 0 })
        #expect(intervals.allSatisfy { $0.average <= $0.maximum && $0.average >= $0.minimum })
    }

    @Test("A default configuration for the kind carries a monthly step")
    func defaultStep() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let config = ReportKind.averageBalance.defaultConfiguration(for: model)
        #expect(config.step == .month)
    }
}
