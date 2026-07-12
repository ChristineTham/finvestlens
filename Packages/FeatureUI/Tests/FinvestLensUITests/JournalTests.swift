//
//  JournalTests.swift
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
@Suite("Journal / general ledger")
struct JournalTests {

    @Test("Per-account journal shows all legs; general ledger shows every txn")
    func journal() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "Groceries",
                                 currency: .aud, splits: [
            SplitInput(accountID: food, value: dec("50")),
            SplitInput(accountID: bank, value: dec("-50")),
        ])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1), description: "Pay",
                                 currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("100")),
            SplitInput(accountID: salary, value: dec("-100")),
        ])

        // Journal for Bank: both transactions touch Bank.
        let bankJournal = model.journalEntries(forAccountID: bank)
        #expect(bankJournal.count == 2)
        #expect(bankJournal.first?.lines.count == 2)
        #expect(bankJournal.first?.lines.contains { $0.accountName == "Food" } == true)
        #expect(bankJournal.first?.lines.contains { $0.isFocusAccount } == true)

        // Journal for Food: only the groceries transaction.
        #expect(model.journalEntries(forAccountID: food).count == 1)

        // General ledger: every transaction.
        #expect(model.journalEntries(forAccountID: nil).count == 2)
    }
}
