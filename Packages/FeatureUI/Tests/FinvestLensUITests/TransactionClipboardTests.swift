//
//  TransactionClipboardTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's Cut / Copy / Paste Transaction.
//
//  Duplicate already covered copying a transaction where it stands, so what the
//  clipboard is for is the other register — and the other book. That makes
//  account resolution the interesting part: a GUID is the answer within a book
//  and means nothing outside one.
//
//  These share a process-wide pasteboard, so each test writes what it expects to
//  read rather than assuming it starts empty.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite(.serialized)
struct TransactionClipboardTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let food: GncGUID
        let txn: GncGUID
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let txn = try model.addTransaction(
            date: day(3), description: "Groceries", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -25, memo: "card", action: "Withdrawal"),
                     SplitInput(accountID: food, value: 25)])
        return Fixture(model: model, url: url, bank: bank, food: food, txn: txn)
    }

    @Test("Copy then paste makes a second, identical transaction")
    func copyPaste() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        #expect(f.model.copyTransaction(f.txn))
        #expect(f.model.canPasteTransaction)

        let pastedID = try f.model.pasteTransaction()
        #expect(pastedID != f.txn)

        let book = try #require(f.model.book)
        let pasted = try #require(book.transaction(with: pastedID))
        #expect(pasted.transactionDescription == "Groceries")
        #expect(pasted.datePosted == day(3))
        #expect(pasted.splits.map(\.value).sorted() == [-25, 25])
        #expect(pasted.isBalanced)
        // The original is untouched.
        #expect(book.transaction(with: f.txn) != nil)
        #expect(book.transactions.count == 2)
    }

    @Test("Memo and action travel with the transaction")
    func memoAndActionSurvive() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.copyTransaction(f.txn)
        let pasted = try #require(f.model.book?.transaction(with: try f.model.pasteTransaction()))
        #expect(pasted.splits.contains { $0.memo == "card" && $0.action == "Withdrawal" })
    }

    /// A pasted transaction is a new one that nobody has agreed to — the same
    /// reasoning that makes Duplicate leave reconcile state behind.
    @Test("A pasted transaction arrives unreconciled, with its own identity")
    func pastedIsNew() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let book = try #require(f.model.book)
        for split in try #require(book.transaction(with: f.txn)).splits {
            split.reconcileState = .reconciled
        }

        f.model.copyTransaction(f.txn)
        let pasted = try #require(book.transaction(with: try f.model.pasteTransaction()))
        #expect(pasted.splits.allSatisfy { $0.reconcileState == .notReconciled })

        let originalSplitIDs = Set(try #require(book.transaction(with: f.txn)).splits.map(\.guid))
        #expect(pasted.splits.allSatisfy { !originalSplitIDs.contains($0.guid) })
    }

    @Test("Cut copies it and takes it away")
    func cut() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(f.model.cutTransaction(f.txn))

        let book = try #require(f.model.book)
        #expect(book.transaction(with: f.txn) == nil)
        // …and it is on the clipboard, so it can come back somewhere else.
        #expect(f.model.canPasteTransaction)
        let pastedID = try f.model.pasteTransaction()
        #expect(book.transaction(with: pastedID)?.transactionDescription == "Groceries")
    }

    /// One action to the person doing it, so one Undo.
    @Test("Cut is a single undo")
    func cutIsUndoable() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let undo = UndoManager()
        f.model.undoManager = undo
        undo.removeAllActions()

        f.model.cutTransaction(f.txn)
        #expect(f.model.book?.transaction(with: f.txn) == nil)
        undo.undo()
        #expect(f.model.book?.transaction(with: f.txn) != nil)
    }

    /// The case the pasteboard exists for. A GUID from another file resolves to
    /// nothing, so the full name is what lands it.
    @Test("Pasting into another book resolves accounts by name")
    func pasteAcrossBooks() throws {
        let source = try makeFixture()
        defer { source.model.close(); try? FileManager.default.removeItem(at: source.url) }
        source.model.copyTransaction(source.txn)

        // A different book, with accounts of the same names and different ids.
        let otherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let other = AppModel()
        try other.newDocument(at: otherURL)
        defer { other.close(); try? FileManager.default.removeItem(at: otherURL) }
        _ = try #require(other.addAccount(name: "Bank", type: .bank))
        _ = try #require(other.addAccount(name: "Food", type: .expense))

        let pastedID = try other.pasteTransaction()
        let pasted = try #require(other.book?.transaction(with: pastedID))
        #expect(pasted.splits.compactMap { $0.account?.name }.sorted() == ["Bank", "Food"])
        #expect(pasted.isBalanced)
    }

    /// Refused by name rather than quietly re-pointed at Imbalance, which would
    /// be the paste deciding where someone's money went.
    @Test("Pasting where an account does not exist is refused, by name")
    func pasteMissingAccount() throws {
        let source = try makeFixture()
        defer { source.model.close(); try? FileManager.default.removeItem(at: source.url) }
        source.model.copyTransaction(source.txn)

        let otherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let other = AppModel()
        try other.newDocument(at: otherURL)
        defer { other.close(); try? FileManager.default.removeItem(at: otherURL) }
        _ = try #require(other.addAccount(name: "Bank", type: .bank))
        // No "Food" here.

        #expect(throws: AppModel.PasteError.unknownAccount("Food")) {
            try other.pasteTransaction()
        }
        #expect(other.book?.transactions.isEmpty == true)
        #expect(other.describe(AppModel.PasteError.unknownAccount("Food")).contains("Food"))
    }

    @Test("Copying an unknown transaction copies nothing")
    func copyUnknown() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(!f.model.copyTransaction(.random()))
        #expect(!f.model.cutTransaction(.random()))
    }

    /// The pasteboard carries text as well, so pasting into a note gives
    /// something to read rather than nothing.
    @Test("A copied transaction is also readable text")
    func textRepresentation() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.copyTransaction(f.txn)
        let clipboard = try #require(TransactionPasteboard.read())
        let text = TransactionPasteboard.describe(clipboard)
        #expect(text.contains("Groceries"))
        #expect(text.contains("Bank"))
    }
}
