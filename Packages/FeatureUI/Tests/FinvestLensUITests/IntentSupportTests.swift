//
//  IntentSupportTests.swift
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
@Suite("Intent support summaries")
struct IntentSupportTests {

    @Test("Net-worth summary reads the last-opened book")
    func netWorth() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)   // records the last-book path
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let opening = try #require(model.addAccount(name: "Opening", type: .equity))
        try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "Open",
                                 currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("1000")),
            SplitInput(accountID: opening, value: dec("-1000")),
        ])
        try model.save()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let summary = IntentSupport.netWorthSummary()
        #expect(summary.contains("net worth"))
        #expect(summary.contains("1,000") || summary.contains("1000"))
    }

    @Test("No book yields a friendly message")
    func noBook() {
        UserDefaults.standard.removeObject(forKey: "finvestlens.lastBookPath")
        #expect(IntentSupport.netWorthSummary().contains("No FinvestLens book"))
    }
}
