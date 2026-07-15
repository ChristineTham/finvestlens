//
//  FindTests.swift
//  FinvestLens — FeatureUI
//
//  Driving the structured Find (⌘F) from the model.
//
//  The engine finds splits; this layer rolls them up to one row per
//  transaction, which is what the results table shows. The split that matched
//  is kept, because it is the honest answer to "show me where this is" — see
//  ``showInRegisterUsesTheMatchedSplit``.
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

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(d) * 86_400) }

@MainActor
@Suite("Structured find")
struct StructuredFindTests {

    private func book() throws -> (AppModel, URL, GncGUID, GncGUID) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "CDIA", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        _ = model.addTransfer(from: income, to: bank, amount: dec("100"), date: day(0), description: "Pay one")
        _ = model.addTransfer(from: income, to: bank, amount: dec("50"), date: day(5), description: "Pay two")
        return (model, url, bank, income)
    }

    private func query(_ test: FindTest, matchAll: Bool = true) -> FindQuery {
        FindQuery(criteria: [FindCriterion(test: test)], matchAll: matchAll)
    }

    @Test("A find fills the results and marks the search active")
    func findFillsResults() throws {
        let (model, url, _, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.text(.description, .contains, "Pay one", matchCase: false)))

        #expect(model.searchResults.count == 1)
        #expect(model.searchResults.first?.description == "Pay one")
        #expect(model.isSearching, "the results pane must show")
        #expect(model.findQuery != nil)
    }

    /// Both legs of a transaction match a description search; the table shows
    /// transactions, so the two splits must collapse to one row.
    @Test("Splits roll up to one row per transaction")
    func splitsRollUp() throws {
        let (model, url, _, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.text(.description, .contains, "Pay", matchCase: false)))
        #expect(model.searchResults.count == 2, "two transactions, not four splits")
    }

    @Test("Results are newest first")
    func resultsAreNewestFirst() throws {
        let (model, url, _, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.text(.description, .contains, "Pay", matchCase: false)))
        #expect(model.searchResults.map(\.description) == ["Pay two", "Pay one"])
    }

    @Test("A date criterion finds by date, which free text never could")
    func findByDate() throws {
        let (model, url, _, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.date(.posted, .isOnOrAfter, day(3))))
        #expect(model.searchResults.map(\.description) == ["Pay two"])
    }

    @Test("A reconcile criterion finds by state")
    func findByReconcileState() throws {
        let (model, url, bank, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.selectedAccountID = bank
        let row = try #require(model.registerRows.first { $0.amount == dec("50") })
        model.cycleReconcileState(splitID: row.id)      // n → c

        model.runFind(query(.reconcile(.isOneOf, [.cleared])))
        #expect(model.searchResults.map(\.description) == ["Pay two"])
    }

    // MARK: The two searches are alternatives

    @Test("Typing in the search bar replaces a find")
    func typingReplacesFind() throws {
        let (model, url, _, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.text(.description, .contains, "Pay", matchCase: false)))
        #expect(model.findQuery != nil)

        model.searchQuery = "Pay one"
        #expect(model.findQuery == nil, "the bar wins; two searches must not both be live")
        #expect(model.searchResults.count == 1)
    }

    /// `runFind` empties the text bar on its way in, which fires `runSearch`.
    /// This pins the end state — bar empty, find live, no stale notices — not
    /// the ordering that produces it: `runFind` sets `findQuery` after the
    /// `didSet` has run, so no arrangement of `runSearch` can lose it.
    @Test("Running a find leaves the bar empty and the find live")
    func findSurvivesClearingTheBar() throws {
        let (model, url, _, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.searchQuery = "Pay one"
        model.runFind(query(.text(.description, .contains, "Pay two", matchCase: false)))

        #expect(model.searchQuery.isEmpty)
        #expect(model.findQuery != nil)
        #expect(model.searchResults.map(\.description) == ["Pay two"])
        #expect(model.searchNotices.isEmpty)
    }

    @Test("Clearing a find empties the results")
    func clearFind() throws {
        let (model, url, _, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.text(.description, .contains, "Pay", matchCase: false)))
        model.clearFind()

        #expect(model.findQuery == nil)
        #expect(model.searchResults.isEmpty)
        #expect(!model.isSearching)
    }

    @Test("Closing a book ends the find")
    func closeEndsFind() throws {
        let (model, url, _, _) = try book()
        defer { try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.text(.description, .contains, "Pay", matchCase: false)))
        model.close()

        #expect(model.findQuery == nil)
        #expect(!model.isSearching)
    }

    // MARK: Editing from the results

    /// Editing a result must not throw you out of the result set — you are
    /// working through a list.
    @Test("An edit refreshes the find rather than dropping it")
    func editKeepsTheFindAlive() throws {
        let (model, url, bank, income) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.text(.description, .contains, "Pay", matchCase: false)))
        let target = try #require(model.searchResults.first { $0.description == "Pay two" })

        try model.updateTransaction(
            id: target.id, date: day(5), description: "Pay two amended", currency: .aud,
            splits: [SplitInput(accountID: bank, value: dec("50")),
                     SplitInput(accountID: income, value: dec("-50"))])

        #expect(model.findQuery != nil, "still finding")
        #expect(model.searchResults.count == 2, "and the amended row still matches 'Pay'")
        #expect(model.searchResults.contains { $0.description == "Pay two amended" })
    }

    /// A transaction edited out of the criteria leaves the results, because the
    /// find is re-run rather than patched.
    @Test("An edit that no longer matches drops out of the results")
    func editOutOfTheResults() throws {
        let (model, url, bank, income) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.text(.description, .contains, "Pay", matchCase: false)))
        let target = try #require(model.searchResults.first { $0.description == "Pay two" })

        try model.updateTransaction(
            id: target.id, date: day(5), description: "Refund", currency: .aud,
            splits: [SplitInput(accountID: bank, value: dec("50")),
                     SplitInput(accountID: income, value: dec("-50"))])

        #expect(model.searchResults.map(\.description) == ["Pay one"])
    }

    // MARK: Show in register

    /// The payoff for keeping the matched split. Searching "Account is Salary"
    /// and asking to see it must open **Salary** — the heuristic prefers the
    /// balance-sheet leg and would open CDIA, which is not what was asked for.
    @Test("Show in Register opens the account the find matched")
    func showInRegisterUsesTheMatchedSplit() throws {
        let (model, url, bank, income) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.account(.isOneOf, [income])))
        let result = try #require(model.searchResults.first)

        // The heuristic on its own would say CDIA.
        #expect(model.registerAccountID(forTransaction: result.id) == bank)

        model.showInRegister(result.id)
        #expect(model.selectedAccountID == income, "the find matched the Salary leg")

        let pending = try #require(model.pendingRegisterSplitID)
        #expect(model.book?.split(with: pending)?.account?.guid == income)
    }

    @Test("Show in Register ends the find")
    func showInRegisterEndsFind() throws {
        let (model, url, _, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(query(.text(.description, .contains, "Pay one", matchCase: false)))
        let result = try #require(model.searchResults.first)

        model.showInRegister(result.id)

        #expect(model.findQuery == nil)
        #expect(!model.isSearching, "otherwise the results stay in the detail pane")
        #expect(!model.registerRows.isEmpty)
    }

    // MARK: Degenerate

    @Test("An empty query finds nothing and stays out of the way")
    func emptyQuery() throws {
        let (model, url, _, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.runFind(FindQuery())
        #expect(model.searchResults.isEmpty)
    }
}
