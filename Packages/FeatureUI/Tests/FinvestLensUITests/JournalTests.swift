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

    /// A book with `count` dated transactions, newest last.
    private func pagedModel(_ count: Int, at url: URL) throws -> AppModel {
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        for i in 0..<count {
            try model.addTransaction(date: Date(timeIntervalSince1970: TimeInterval(i)),
                                     description: "Txn \(i)", currency: .aud, splits: [
                SplitInput(accountID: food, value: dec("1")),
                SplitInput(accountID: bank, value: dec("-1")),
            ])
        }
        return model
    }

    @Test("The journal windows to the newest page, and can be extended")
    func windowing() throws {
        let url = tempURL()
        let model = try pagedModel(10, at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        #expect(model.journalEntryCount(forAccountID: nil) == 10)

        // A page holds the *newest* transactions, still oldest-first — so the
        // last entry is the newest, which is what the view scrolls to.
        let page = model.journalEntries(forAccountID: nil, limit: 4)
        #expect(page.count == 4)
        #expect(page.first?.description == "Txn 6")
        #expect(page.last?.description == "Txn 9")

        // "Show Earlier" widens the window towards the oldest.
        let wider = model.journalEntries(forAccountID: nil, limit: 8)
        #expect(wider.first?.description == "Txn 2")
        #expect(wider.last?.description == "Txn 9")

        // A limit past the end just yields everything; a silly limit is safe.
        #expect(model.journalEntries(forAccountID: nil, limit: 500).count == 10)
        #expect(model.journalEntries(forAccountID: nil, limit: 0).isEmpty)
        #expect(model.journalEntries(forAccountID: nil, limit: -5).isEmpty)
    }

    @Test("Cached journal transactions are invalidated when the book changes")
    func cacheInvalidation() throws {
        let url = tempURL()
        let model = try pagedModel(3, at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.accountTree.first { $0.name == "Bank" }?.id)

        #expect(model.journalEntryCount(forAccountID: nil) == 3)      // populates the cache
        #expect(model.journalEntryCount(forAccountID: bank) == 3)

        let food = try #require(model.accountTree.first { $0.name == "Food" }?.id)
        try model.addTransaction(date: Date(timeIntervalSince1970: 99), description: "Later",
                                 currency: .aud, splits: [
            SplitInput(accountID: food, value: dec("2")),
            SplitInput(accountID: bank, value: dec("-2")),
        ])
        // A stale cache here would hide the new transaction from the journal.
        #expect(model.journalEntryCount(forAccountID: nil) == 4)
        #expect(model.journalEntryCount(forAccountID: bank) == 4)
        #expect(model.journalEntries(forAccountID: nil).last?.description == "Later")

        // Deletions invalidate too.
        let latest = try #require(model.journalEntries(forAccountID: nil).last?.id)
        model.deleteTransaction(latest)
        #expect(model.journalEntryCount(forAccountID: nil) == 3)
        #expect(model.journalEntries(forAccountID: nil).last?.description == "Txn 2")

        // Closing drops the cache rather than serving another book's entries.
        model.close()
        #expect(model.journalEntryCount(forAccountID: nil) == 0)
    }
}
