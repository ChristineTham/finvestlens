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

        // Journal for Bank: a heading per transaction plus its legs.
        let bankJournal = model.journalRows(forAccountID: bank)
        #expect(bankJournal.filter(\.isHeading).count == 2)
        #expect(bankJournal.count == 6)                      // 2 headings + 4 legs
        #expect(bankJournal.first?.isHeading == true)
        #expect(bankJournal.first?.text == "Groceries")
        #expect(bankJournal.contains { $0.text == "Food" && !$0.isHeading })
        #expect(bankJournal.contains { $0.isFocusAccount })

        // Journal for Food: only the groceries transaction.
        #expect(model.journalRows(forAccountID: food).filter(\.isHeading).count == 1)

        // General ledger: every transaction, oldest first.
        let ledger = model.journalRows(forAccountID: nil)
        #expect(ledger.filter(\.isHeading).count == 2)
        #expect(ledger.first?.text == "Groceries")
        #expect(ledger.last?.isHeading == false)             // ends on a leg
        // Nothing is a focus account in the general ledger.
        #expect(!ledger.contains { $0.isFocusAccount })
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

    @Test("The journal holds the whole book and jumps to its true ends")
    func wholeJournalAndEdges() throws {
        let url = tempURL()
        let model = try pagedModel(10, at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        // No windowing: every transaction is present, oldest first.
        let rows = model.journalRows(forAccountID: nil)
        #expect(rows.filter(\.isHeading).count == 10)
        #expect(model.journalEntryCount(forAccountID: nil) == 10)
        #expect(rows.first?.text == "Txn 0")
        #expect(rows.filter(\.isHeading).last?.text == "Txn 9")

        // ⌘↑ reaches the oldest posting in the book, ⌘↓ the newest — the same
        // meaning as in the basic register, not "the oldest currently loaded".
        let oldest = try #require(model.journalEdgeRowID(forAccountID: nil, newest: false))
        let newest = try #require(model.journalEdgeRowID(forAccountID: nil, newest: true))
        #expect(oldest == rows.first?.id)
        #expect(newest == rows.last?.id)

        // An empty journal has no edge rather than a crash.
        let unused = try #require(model.addAccount(name: "Unused", type: .expense))
        #expect(model.journalEdgeRowID(forAccountID: unused, newest: true) == nil)
        #expect(model.journalRows(forAccountID: unused).isEmpty)
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
        #expect(model.journalRows(forAccountID: nil).filter(\.isHeading).last?.text == "Later")

        // Deletions invalidate too.
        let latest = try #require(model.journalRows(forAccountID: nil).filter(\.isHeading).last?.id)
        model.deleteTransaction(latest)
        #expect(model.journalEntryCount(forAccountID: nil) == 3)
        #expect(model.journalRows(forAccountID: nil).filter(\.isHeading).last?.text == "Txn 2")

        // Closing drops the cache rather than serving another book's entries.
        model.close()
        #expect(model.journalEntryCount(forAccountID: nil) == 0)
        #expect(model.journalRows(forAccountID: nil).isEmpty)
    }
}
