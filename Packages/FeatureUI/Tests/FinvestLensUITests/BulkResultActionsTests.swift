//
//  BulkResultActionsTests.swift
//  FinvestLens — FeatureUI
//
//  Acting on many search results at once. The results table always allowed
//  selecting several rows and the menu acted on the first — "find last month's
//  cheques, mark them cleared" was forty right-clicks.
//
//  Alongside: the refresh bug the feature exposed. An edit used to re-run the
//  last find query, which collapses a refined result set back to that one
//  query's matches. The fix replays the whole search pipeline, so results stay
//  live (rows re-evaluate as they are edited) *and* refinements stay in force —
//  editing the results is what the results are for.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Bulk result actions")
struct BulkResultActionsTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let food: GncGUID
        let txns: [GncGUID]
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        var txns: [GncGUID] = []
        for n in 0..<4 {
            txns.append(try model.addTransaction(
                date: day(n), description: "Cheque \(n)", currency: .aud,
                splits: [SplitInput(accountID: bank, value: Decimal(-10 - n)),
                         SplitInput(accountID: food, value: Decimal(10 + n))]))
        }
        return Fixture(model: model, url: url, bank: bank, food: food, txns: txns)
    }

    private func findCheques(_ f: Fixture) {
        f.model.runFind(FindQuery(criteria: [
            FindCriterion(test: .account(.isOneOf, [f.bank]))]))
    }

    @Test("Deleting several results is one edit and one undo")
    func bulkDelete() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let undo = UndoManager()
        f.model.undoManager = undo
        undo.removeAllActions()

        f.model.deleteTransactions(Array(f.txns.prefix(3)))
        #expect(f.model.book?.transactions.count == 1)

        undo.undo()
        #expect(f.model.book?.transactions.count == 4)
    }

    @Test("Voiding several results voids all their splits")
    func bulkVoid() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.voidTransactions(Array(f.txns.prefix(2)))
        let book = try #require(f.model.book)
        for id in f.txns.prefix(2) {
            #expect(f.model.isVoided(id))
        }
        #expect(!f.model.isVoided(f.txns[3]))
        // The book's balance no longer counts the voided ones (cheques 2 and 3
        // remain: -12 and -13).
        let bank = try #require(book.account(with: f.bank))
        let remaining = book.balance(of: bank).amount
        #expect(remaining == Decimal(-25))
    }

    /// The reconcile bulk acts on the *matched* split of each result — the leg
    /// the search was about, not every leg of the transaction.
    @Test("Bulk reconcile marks the matched splits and only those")
    func bulkReconcileMarksMatches() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        findCheques(f)
        #expect(f.model.searchResults.count == 4)

        f.model.setReconcileStateOfMatches(in: f.txns, to: .cleared)

        let book = try #require(f.model.book)
        for id in f.txns {
            let txn = try #require(book.transaction(with: id))
            let bankLeg = try #require(txn.splits.first { $0.account?.guid == f.bank })
            let foodLeg = try #require(txn.splits.first { $0.account?.guid == f.food })
            #expect(bankLeg.reconcileState == .cleared)      // searched for
            #expect(foodLeg.reconcileState == .notReconciled) // not
        }
    }

    @Test("Bulk reconcile without a find does nothing rather than guessing")
    func bulkReconcileNeedsAFind() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        // No find has run, so no result remembers a matched split.
        f.model.setReconcileStateOfMatches(in: f.txns, to: .cleared)
        let book = try #require(f.model.book)
        let bank = try #require(book.account(with: f.bank))
        #expect(book.splits(for: bank).allSatisfy { $0.reconcileState == .notReconciled })
    }

    // MARK: The refresh that must not forget

    /// Editing a result must leave a *refined* result set refined. The refresh
    /// used to re-run the last query, which quietly threw the refinement away.
    @Test("A refined result set survives an edit")
    func refinedResultsSurviveEdits() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        findCheques(f)
        // Narrow to the two cheapest cheques.
        f.model.runFind(FindQuery(criteria: [
            FindCriterion(test: .number(.value, .greaterThanOrEqual, -11))]), mode: .refine)
        #expect(f.model.searchResults.map(\.description).sorted() == ["Cheque 0", "Cheque 1"])

        // Edit one of them — the refinement must hold, with the edit visible.
        let edit = try #require(f.model.editData(forTransaction: f.txns[0]))
        _ = try f.model.updateTransaction(id: f.txns[0], date: edit.date,
                                          description: "Cheque 0 (fixed)",
                                          currency: edit.currency, splits: edit.splits)
        #expect(f.model.searchResults.map(\.description).sorted()
                == ["Cheque 0 (fixed)", "Cheque 1"])
    }

    /// Deleting a result removes its row and keeps the rest — the replayed
    /// pipeline simply no longer finds it.
    @Test("Deleting results removes their rows and keeps the rest")
    func deletePrunesResults() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        findCheques(f)
        f.model.deleteTransactions([f.txns[0], f.txns[2]])
        #expect(f.model.searchResults.map(\.description).sorted() == ["Cheque 1", "Cheque 3"])
        #expect(f.model.hasFindResults)
    }
}
