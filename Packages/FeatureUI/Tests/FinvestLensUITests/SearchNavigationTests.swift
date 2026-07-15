//
//  SearchNavigationTests.swift
//  FinvestLens — FeatureUI
//
//  Acting on a search result. GnuCash's Find opens its results as a register,
//  so a result is a place you work, not just a row you read; ``showInRegister``
//  is the equivalent path from a result back to the transaction.
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

@MainActor
@Suite("Search navigation")
struct SearchNavigationTests {

    private func book() throws -> (AppModel, URL, GncGUID, GncGUID) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        let txn = try model.addTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_000), description: "Acme payroll",
            currency: .aud,
            splits: [SplitInput(accountID: bank, value: dec("100")),
                     SplitInput(accountID: income, value: dec("-100"))])
        return (model, url, txn, bank)
    }

    /// The whole point: a result must be able to put you in the register. That
    /// means clearing the query — a non-empty one keeps the results in the
    /// detail pane, so the register would never be seen.
    @Test("Showing a result in its register clears the search and selects the account")
    func showInRegisterClearsSearchAndSelectsAccount() throws {
        let (model, url, txn, bank) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.searchQuery = "Acme"
        #expect(model.searchResults.count == 1)

        model.showInRegister(txn)

        #expect(model.searchQuery.isEmpty)
        #expect(model.searchResults.isEmpty, "results no longer occupy the detail pane")
        #expect(model.selectedAccountID == bank)
        #expect(!model.registerRows.isEmpty)
    }

    /// The register is asked to land on the transaction, not merely its account.
    @Test("Showing a result names the row to land on")
    func showInRegisterNamesTheRow() throws {
        let (model, url, txn, bank) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.showInRegister(txn)

        let pending = try #require(model.pendingRegisterSplitID)
        let row = try #require(model.registerRows.first { $0.id == pending })
        #expect(row.description == "Acme payroll")
        // It is the split in the account we switched to, not the other leg.
        let split = try #require(model.book?.split(with: pending))
        #expect(split.account?.guid == bank)
    }

    /// One-shot: it names one split of one account, so a second register must
    /// not inherit it.
    @Test("The pending row is consumed once")
    func pendingSelectionIsOneShot() throws {
        let (model, url, txn, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.showInRegister(txn)
        #expect(model.pendingRegisterSplitID != nil)

        #expect(model.consumePendingRegisterSelection() != nil)
        #expect(model.pendingRegisterSplitID == nil)
        #expect(model.consumePendingRegisterSelection() == nil)
    }

    /// Imported transactions are entered category-leg-first, so "the first
    /// split" lands in Imbalance-AUD — technically a leg of the transaction,
    /// and useless: it says nothing about where the money moved. The card is
    /// the register to open, whatever order the splits are in.
    @Test("A result opens in its bank/card register, not its category")
    func showInRegisterPrefersTheBalanceSheetLeg() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        // Imbalance-AUD is typed `.bank`, exactly as Scrub creates it — so it
        // looks like a real balance-sheet leg and has to be skipped by name.
        let imbalance = try #require(model.addAccount(name: "Imbalance-AUD", type: .bank))
        let card = try #require(model.addAccount(name: "ANZ VISA", type: .credit))
        // Category leg first, exactly as the bank-file importer writes them.
        let txn = try model.addTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_000), description: "COLES 5773",
            currency: .aud,
            splits: [SplitInput(accountID: imbalance, value: dec("47.75")),
                     SplitInput(accountID: card, value: dec("-47.75"))])

        #expect(model.registerAccountID(forTransaction: txn) == card)

        model.showInRegister(txn)
        #expect(model.selectedAccountID == card)
        let pending = try #require(model.pendingRegisterSplitID)
        #expect(model.book?.split(with: pending)?.account?.guid == card)
    }

    /// A category-to-category correction has no balance-sheet leg; it still has
    /// to open somewhere.
    @Test("A transaction with no bank leg still opens")
    func showInRegisterFallsBackToFirstSplit() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let dining = try #require(model.addAccount(name: "Dining", type: .expense))
        let txn = try model.addTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_000), description: "Recategorise",
            currency: .aud,
            splits: [SplitInput(accountID: groceries, value: dec("20")),
                     SplitInput(accountID: dining, value: dec("-20"))])

        #expect(model.registerAccountID(forTransaction: txn) == groceries)
        model.showInRegister(txn)
        #expect(model.selectedAccountID == groceries)
    }

    @Test("Showing an unknown transaction changes nothing")
    func showInRegisterIgnoresUnknown() throws {
        let (model, url, _, _) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.searchQuery = "Acme"
        model.showInRegister(.random())

        #expect(model.searchQuery == "Acme", "a bad id must not clear the user's search")
        #expect(model.selectedAccountID == nil)
        #expect(model.pendingRegisterSplitID == nil)
    }
}
