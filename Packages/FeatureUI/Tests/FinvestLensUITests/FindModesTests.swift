//
//  FindModesTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's "Type of search" (new / refine / add / delete), saved find
//  queries, and the two criteria Find was missing. The modes compose over the
//  *split* set for the same reason the criteria test splits: refining "account
//  is CDIA" by "is reconciled" must mean one split that is both, not a
//  transaction that has each somewhere.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Find modes and saved queries")
struct FindModesTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let food: GncGUID
        let fuel: GncGUID
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let fuel = try #require(model.addAccount(name: "Fuel", type: .expense))
        _ = try model.addTransaction(date: day(0), description: "Woolies", currency: .aud,
                                     splits: [SplitInput(accountID: bank, value: -30),
                                              SplitInput(accountID: food, value: 30)])
        _ = try model.addTransaction(date: day(1), description: "Woolies petrol", currency: .aud,
                                     splits: [SplitInput(accountID: bank, value: -50),
                                              SplitInput(accountID: fuel, value: 50)])
        _ = try model.addTransaction(date: day(2), description: "Coles", currency: .aud,
                                     splits: [SplitInput(accountID: bank, value: -20),
                                              SplitInput(accountID: food, value: 20)])
        return Fixture(model: model, url: url, bank: bank, food: food, fuel: fuel)
    }

    private func descriptionQuery(_ needle: String) -> FindQuery {
        FindQuery(criteria: [FindCriterion(test: .text(.description, .contains, needle,
                                                       matchCase: false))])
    }

    private func results(_ f: Fixture) -> [String] {
        f.model.searchResults.map(\.description).sorted()
    }

    @Test("A new search replaces whatever was showing")
    func newReplaces() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.runFind(descriptionQuery("Woolies"))
        #expect(results(f) == ["Woolies", "Woolies petrol"])
        f.model.runFind(descriptionQuery("Coles"), mode: .new)
        #expect(results(f) == ["Coles"])
    }

    @Test("Refine keeps only results that also match")
    func refineNarrows() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.runFind(descriptionQuery("Woolies"))
        f.model.runFind(descriptionQuery("petrol"), mode: .refine)
        #expect(results(f) == ["Woolies petrol"])
    }

    @Test("Add widens the results")
    func addWidens() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.runFind(descriptionQuery("Coles"))
        f.model.runFind(descriptionQuery("petrol"), mode: .add)
        #expect(results(f) == ["Coles", "Woolies petrol"])
    }

    @Test("Delete removes matches from the results")
    func deleteRemoves() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.runFind(descriptionQuery("Woolies"))
        f.model.runFind(descriptionQuery("petrol"), mode: .delete)
        #expect(results(f) == ["Woolies"])
    }

    /// The reason the modes work on splits: refining by account must keep the
    /// matched split pointed at the account refined to.
    @Test("Refining composes on splits, not transactions")
    func refineIsSplitwise() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        // All bank legs (three), then refine to value ≤ -30: the Coles bank leg
        // (-20) drops even though its transaction matched the first query.
        f.model.runFind(FindQuery(criteria: [
            FindCriterion(test: .account(.isOneOf, [f.bank]))]))
        #expect(f.model.searchResults.count == 3)
        f.model.runFind(FindQuery(criteria: [
            FindCriterion(test: .number(.value, .lessThanOrEqual, -30))]), mode: .refine)
        #expect(results(f) == ["Woolies", "Woolies petrol"])
    }

    @Test("Clearing a find forgets the working set")
    func clearForgets() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.runFind(descriptionQuery("Woolies"))
        #expect(f.model.hasFindResults)
        f.model.clearFind()
        #expect(!f.model.hasFindResults)
        // A refine after clearing has nothing to narrow — it finds nothing
        // rather than resurrecting the old results.
        f.model.runFind(descriptionQuery("Woolies"), mode: .refine)
        #expect(f.model.searchResults.isEmpty)
    }

    // MARK: New criteria

    /// "All Accounts": the transaction posts to every chosen account — a
    /// transfer between them, not either of them.
    @Test("All Accounts means the transaction touches every one")
    func allAccounts() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.runFind(FindQuery(criteria: [
            FindCriterion(test: .allAccounts([f.bank, f.food]))]))
        #expect(results(f) == ["Coles", "Woolies"])
        // Bank+fuel finds only the petrol one.
        f.model.runFind(FindQuery(criteria: [
            FindCriterion(test: .allAccounts([f.bank, f.fuel]))]))
        #expect(results(f) == ["Woolies petrol"])
        // An empty set matches nothing, like the empty query — not everything.
        f.model.runFind(FindQuery(criteria: [FindCriterion(test: .allAccounts([]))]))
        #expect(f.model.searchResults.isEmpty)
    }

    /// Closing entries are marked with GnuCash's `book_closing` slot, which the
    /// importer carries through.
    @Test("Closing Entries reads the book_closing slot")
    func closingEntries() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let book = try #require(f.model.book)
        let closing = try #require(book.transactions.first { $0.transactionDescription == "Coles" })
        closing.kvp["book_closing"] = .int64(1)

        f.model.runFind(FindQuery(criteria: [FindCriterion(test: .closing(true))]))
        #expect(results(f) == ["Coles"])
        // The common use: everything that is not year-end bookkeeping.
        f.model.runFind(FindQuery(criteria: [FindCriterion(test: .closing(false))]))
        #expect(results(f) == ["Woolies", "Woolies petrol"])
    }

    // MARK: Saved queries

    @Test("A saved query survives closing and reopening the book")
    func savedQueryPersists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = AppModel()
        try model.newDocument(at: url)
        let query = descriptionQuery("Woolies")
        model.saveFindQuery(query, named: "Groceries")
        try model.save()
        model.close()

        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close() }
        let saved = try #require(reopened.savedFindQueries.first)
        #expect(saved.name == "Groceries")
        #expect(saved.query == query)
    }

    @Test("Saving under an existing name replaces, not duplicates")
    func saveReplacesByName() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.saveFindQuery(descriptionQuery("Woolies"), named: "Mine")
        f.model.saveFindQuery(descriptionQuery("Coles"), named: "Mine")
        #expect(f.model.savedFindQueries.count == 1)
        #expect(f.model.savedFindQueries.first?.query == descriptionQuery("Coles")
                    .with(id: f.model.savedFindQueries.first?.query.criteria.first?.id))
    }

    @Test("An empty query or a blank name is not worth saving")
    func saveRefusesEmpty() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.saveFindQuery(FindQuery(), named: "Empty")
        f.model.saveFindQuery(descriptionQuery("x"), named: "   ")
        #expect(f.model.savedFindQueries.isEmpty)
    }

    @Test("Deleting a saved query deletes that one")
    func deleteSaved() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.saveFindQuery(descriptionQuery("a"), named: "A")
        f.model.saveFindQuery(descriptionQuery("b"), named: "B")
        let id = try #require(f.model.savedFindQueries.first { $0.name == "A" }?.id)
        f.model.deleteSavedFindQuery(id)
        #expect(f.model.savedFindQueries.map(\.name) == ["B"])
    }
}

private extension FindQuery {
    /// Same query, with the criterion id swapped — ids are fresh per criterion,
    /// so equality of a re-built query needs them aligned.
    func with(id: UUID?) -> FindQuery {
        guard let id, var criterion = criteria.first else { return self }
        criterion.id = id
        return FindQuery(criteria: [criterion], matchAll: matchAll)
    }
}
