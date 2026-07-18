//
//  SearchTagsTests.swift
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
@Suite("Search operators & tags")
struct SearchTagsTests {

    private func model() throws -> (AppModel, GncGUID, GncGUID, URL) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Groceries", type: .expense))
        return (model, bank, food, url)
    }

    @Test("Tags persist and drive tag: search")
    func tagSearch() throws {
        let (model, bank, food, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "Woolworths",
                                 currency: .aud, splits: [
            SplitInput(accountID: food, value: dec("50")),
            SplitInput(accountID: bank, value: dec("-50")),
        ], tags: ["reimbursable", "work"])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1), description: "Coles",
                                 currency: .aud, splits: [
            SplitInput(accountID: food, value: dec("30")),
            SplitInput(accountID: bank, value: dec("-30")),
        ])

        model.searchQuery = "tag:work"
        #expect(model.searchResults.count == 1)
        #expect(model.searchResults.first?.description == "Woolworths")
    }

    @Test("Operator tokens are ANDed")
    func operators() throws {
        let (model, bank, food, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "Woolworths big shop",
                                 currency: .aud, splits: [
            SplitInput(accountID: food, value: dec("150")),
            SplitInput(accountID: bank, value: dec("-150")),
        ])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1), description: "Woolworths small",
                                 currency: .aud, splits: [
            SplitInput(accountID: food, value: dec("10")),
            SplitInput(accountID: bank, value: dec("-10")),
        ])
        model.searchQuery = "account:Groceries amount:>100"
        #expect(model.searchResults.count == 1)
        #expect(model.searchResults.first?.description == "Woolworths big shop")
    }

    @Test("Negation, type:, and has: operators (FR-FIND-01)")
    func negationTypeHas() throws {
        let (model, bank, food, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "Woolworths",
                                 currency: .aud, splits: [
            SplitInput(accountID: food, value: dec("50")),
            SplitInput(accountID: bank, value: dec("-50")),
        ], tags: ["work"])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1), description: "Salary",
                                 currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("100")),
            SplitInput(accountID: food, value: dec("-100")),
        ])

        // Negation: everything that is NOT Woolworths.
        model.searchQuery = "-Woolworths"
        #expect(model.searchResults.map(\.description) == ["Salary"])

        // type: matches a split's account type.
        model.searchQuery = "type:expense"
        #expect(model.searchResults.count == 2)   // both touch Groceries

        // has:tag finds the tagged transaction only.
        model.searchQuery = "has:tag"
        #expect(model.searchResults.map(\.description) == ["Woolworths"])
    }

    @Test("Relative and absolute date parsing (FR-FIND-01)")
    func dateParsing() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 UTC
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let sevenDaysAgo = AppModel.parseSearchDate("-7d", now: now, calendar: cal)
        #expect(sevenDaysAgo == cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now)))
        #expect(AppModel.parseSearchDate("today", now: now, calendar: cal) == cal.startOfDay(for: now))
        #expect(AppModel.parseSearchDate("2023-01-15", now: now, calendar: cal) != nil)
        #expect(AppModel.parseSearchDate("garbage", now: now, calendar: cal) == nil)
    }
}
