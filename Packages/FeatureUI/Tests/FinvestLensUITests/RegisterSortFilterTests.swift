//
//  RegisterSortFilterTests.swift
//  FinvestLens — FeatureUI
//
//  Sorting and filtering a register (GnuCash View ▸ Sort By / Filter By).
//
//  The load-bearing rule, taken from GnuCash itself: the Balance column is the
//  account's balance as of that posting, computed in date order. Sort by amount
//  and every row keeps the balance it had; filter rows away and the survivors
//  keep theirs. Balance is a fact about the account, not about the list.
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
@Suite("Register sort and filter")
struct RegisterSortFilterTests {

    /// Bank account with three postings: +100 (day 0), +50 (day 1), -30 (day 2).
    /// Running balances in date order: 100, 150, 120.
    private func bookWithPostings() throws -> (AppModel, URL, GncGUID) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        let expense = try #require(model.addAccount(name: "Rent", type: .expense))
        _ = model.addTransfer(from: income, to: bank, amount: dec("100"), date: day(0), description: "Big pay")
        _ = model.addTransfer(from: income, to: bank, amount: dec("50"), date: day(1), description: "Small pay")
        _ = model.addTransfer(from: bank, to: expense, amount: dec("30"), date: day(2), description: "Rent")
        model.selectedAccountID = bank
        return (model, url, bank)
    }

    @Test("Standard order is date order, with true running balances")
    func standardOrder() throws {
        let (model, url, _) = try bookWithPostings()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        #expect(model.registerRows.map(\.amount) == [dec("100"), dec("50"), dec("-30")])
        #expect(model.registerRows.map(\.runningBalance) == [dec("100"), dec("150"), dec("120")])
    }

    /// The oracle: GnuCash sorted by amount shows each row's *date-order*
    /// balance, not a running total of the displayed order. Verified against
    /// GnuCash 5 on the reference book before this was written.
    @Test("Sorting by amount re-orders rows but never re-computes balances")
    func sortByAmountKeepsBalances() throws {
        let (model, url, _) = try bookWithPostings()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.registerSort = .amount

        #expect(model.registerRows.map(\.amount) == [dec("-30"), dec("50"), dec("100")])
        // Each row still carries the balance it had in date order.
        #expect(model.registerRows.map(\.runningBalance) == [dec("120"), dec("150"), dec("100")])
    }

    @Test("Reverse order flips the display without touching balances")
    func reverseOrder() throws {
        let (model, url, _) = try bookWithPostings()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.registerSortReversed = true
        #expect(model.registerRows.map(\.amount) == [dec("-30"), dec("50"), dec("100")])
        #expect(model.registerRows.map(\.runningBalance) == [dec("120"), dec("150"), dec("100")])
    }

    @Test("Sorting by description orders case-insensitively")
    func sortByDescription() throws {
        let (model, url, _) = try bookWithPostings()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.registerSort = .description
        #expect(model.registerRows.map(\.description) == ["Big pay", "Rent", "Small pay"])
    }

    /// A hidden split still moved the account, so the rows that remain keep the
    /// balances they have in the full register. Filtering is not a recount.
    @Test("Filtering hides rows without re-computing balances")
    func filterKeepsBalances() throws {
        let (model, url, _) = try bookWithPostings()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        // Clear the middle posting only.
        let middle = try #require(model.registerRows.first { $0.amount == dec("50") })
        model.cycleReconcileState(splitID: middle.id)   // n → c

        model.registerFilter = RegisterFilter(statuses: [.cleared])

        #expect(model.registerRows.count == 1)
        #expect(model.registerRows.first?.amount == dec("50"))
        #expect(model.registerRows.first?.runningBalance == dec("150"),
                "the balance as of that posting, not the total of what is shown")
    }

    @Test("A date range keeps both ends, whole days")
    func filterByDateRange() throws {
        let (model, url, _) = try bookWithPostings()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        // Mid-day bounds must not clip postings on the boundary days.
        model.registerFilter = RegisterFilter(
            statuses: Set(ReconcileState.allCases),
            startDate: day(1).addingTimeInterval(3_600),
            endDate: day(2).addingTimeInterval(3_600))

        #expect(model.registerRows.map(\.amount) == [dec("50"), dec("-30")])
        #expect(model.registerRows.map(\.runningBalance) == [dec("150"), dec("120")])
    }

    @Test("Clearing every status empties the register")
    func filterWithNoStatuses() throws {
        let (model, url, _) = try bookWithPostings()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.registerFilter = RegisterFilter(statuses: [])
        #expect(model.registerRows.isEmpty)
    }

    @Test("Show All restores every row")
    func showAllRestores() throws {
        let (model, url, _) = try bookWithPostings()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.registerFilter = RegisterFilter(statuses: [.reconciled])
        #expect(model.registerRows.isEmpty)

        model.registerFilter = .showAll
        #expect(model.registerRows.count == 3)
        #expect(model.registerFilter.isShowingEverything)
    }

    /// Sort and filter are view state, not book state: the next book must not
    /// open with the last one's rows hidden.
    @Test("Closing a book resets the register view")
    func closeResetsView() throws {
        let (model, url, _) = try bookWithPostings()
        defer { try? FileManager.default.removeItem(at: url) }

        model.registerSort = .amount
        model.registerSortReversed = true
        model.registerFilter = RegisterFilter(statuses: [.reconciled])

        model.close()

        #expect(model.registerSort == .standard)
        #expect(!model.registerSortReversed)
        #expect(model.registerFilter.isShowingEverything)
    }

    /// Voided rows show but do not move the balance — and can be filtered out,
    /// which must still not move it.
    @Test("Filtering out a voided row leaves the balance alone")
    func voidedAndFiltered() throws {
        let (model, url, _) = try bookWithPostings()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let middle = try #require(model.registerRows.first { $0.amount == dec("50") })
        let txn = try #require(model.transactionID(ofSplit: middle.id))
        model.voidTransaction(txn)

        // Voided: 100 then (voided 50) then -30 → balances 100, 100, 70.
        #expect(model.registerRows.map(\.runningBalance) == [dec("100"), dec("100"), dec("70")])

        model.registerFilter = RegisterFilter(
            statuses: Set(ReconcileState.allCases).subtracting([.voided]))
        #expect(model.registerRows.map(\.amount) == [dec("100"), dec("-30")])
        #expect(model.registerRows.map(\.runningBalance) == [dec("100"), dec("70")])
    }
}
