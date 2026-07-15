//
//  SubaccountRegisterTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's Open Subaccounts: one register for an account and everything under
//  it. `Book.balance(of:filter:includingDescendants:)` has had the balance half
//  of this from the start with no production caller — the register was strictly
//  single-account, filtering splits by account identity.
//
//  The part with a wrong answer is the Balance column. A quantity means "so many
//  of the account's own commodity", so a running total across a subtree holding
//  shares *and* dollars is a number of nothing.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Subaccount register")
struct SubaccountRegisterTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let parent: GncGUID
        let child: GncGUID
        let other: GncGUID
    }

    /// Parent with one child, both AUD, plus an unrelated account whose postings
    /// must never appear.
    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let parent = try #require(model.addAccount(name: "Savings", type: .bank))
        let child = try #require(model.addAccount(name: "Holiday", type: .bank, parentID: parent))
        let other = try #require(model.addAccount(name: "Elsewhere", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))

        _ = try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "to parent",
                                     currency: .aud,
                                     splits: [SplitInput(accountID: parent, value: 100),
                                              SplitInput(accountID: income, value: -100)])
        _ = try model.addTransaction(date: Date(timeIntervalSince1970: 86_400), description: "to child",
                                     currency: .aud,
                                     splits: [SplitInput(accountID: child, value: 30),
                                              SplitInput(accountID: income, value: -30)])
        _ = try model.addTransaction(date: Date(timeIntervalSince1970: 172_800), description: "elsewhere",
                                     currency: .aud,
                                     splits: [SplitInput(accountID: other, value: 7),
                                              SplitInput(accountID: income, value: -7)])
        return Fixture(model: model, url: url, parent: parent, child: child, other: other)
    }

    @Test("Off, the register is the account's own postings")
    func withoutSubaccounts() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.parent
        #expect(f.model.registerRows.count == 1)
        #expect(f.model.registerRows.map(\.description) == ["to parent"])
    }

    @Test("On, the register is the subtree's postings, in date order")
    func withSubaccounts() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.parent
        f.model.registerIncludesSubaccounts = true
        #expect(f.model.registerRows.map(\.description) == ["to parent", "to child"])
        // And nothing from outside the subtree.
        #expect(!f.model.registerRows.map(\.description).contains("elsewhere"))
    }

    /// The balance accumulates across the subtree, so the last row reads what
    /// the sidebar shows for the parent including its children.
    @Test("Balances accumulate across the subtree")
    func subtreeBalances() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.parent
        f.model.registerIncludesSubaccounts = true
        #expect(f.model.registerRows.map(\.runningBalance) == [100, 130])

        let book = try #require(f.model.book)
        let account = try #require(book.account(with: f.parent))
        #expect(book.balance(of: account, includingDescendants: true).amount == 130)
    }

    @Test("A subtree row says which account it posted to")
    func rowsNameTheirAccount() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.parent
        f.model.registerIncludesSubaccounts = true
        #expect(f.model.registerRows.map(\.accountName) == ["Savings", "Holiday"])
        // A single-account register has nothing to say here — every row is the
        // same account.
        f.model.registerIncludesSubaccounts = false
        #expect(f.model.registerRows.allSatisfy { $0.accountName.isEmpty })
    }

    /// The one with a wrong answer: shares and dollars do not add up.
    @Test("A subtree of mixed commodities has no running balance")
    func mixedCommoditiesHaveNoBalance() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bhp = Commodity(namespace: .security("ASX"), mnemonic: "BHP",
                            fullName: "BHP", smallestFraction: 10000)
        let parent = try #require(model.addAccount(name: "Portfolio", type: .asset, commodity: .aud))
        let cash = try #require(model.addAccount(name: "Cash", type: .bank,
                                                 commodity: .aud, parentID: parent))
        let shares = try #require(model.addAccount(name: "BHP", type: .stock,
                                                   commodity: bhp, parentID: parent))
        let equity = try #require(model.addAccount(name: "Opening", type: .equity))

        _ = try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "cash in",
                                     currency: .aud,
                                     splits: [SplitInput(accountID: cash, value: 1000),
                                              SplitInput(accountID: equity, value: -1000)])
        _ = try model.addTransaction(date: Date(timeIntervalSince1970: 86_400), description: "buy",
                                     currency: .aud,
                                     splits: [SplitInput(accountID: shares, value: 400, quantity: 10),
                                              SplitInput(accountID: cash, value: -400)])

        model.selectedAccountID = parent
        model.registerIncludesSubaccounts = true
        #expect(model.registerRows.count == 3)
        // 10 shares + $600 is not 610 of anything, so there is no figure to give.
        #expect(model.registerRows.allSatisfy { $0.runningBalance == nil })
        #expect(!model.registerHasBalances)

        // The account's own register, one commodity, still has them.
        model.registerIncludesSubaccounts = false
        model.selectedAccountID = cash
        #expect(model.registerRows.allSatisfy { $0.runningBalance != nil })
        #expect(model.registerHasBalances)
    }

    /// Voided splits show but must not move the balance — the subtree register
    /// has to keep the rule the single-account one already had.
    @Test("A voided split in a subaccount does not move the balance")
    func voidedInSubtree() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let book = try #require(f.model.book)
        let child = try #require(book.account(with: f.child))
        for split in book.splits(for: child) { split.reconcileState = .voided }
        f.model.refreshAll()

        f.model.selectedAccountID = f.parent
        f.model.registerIncludesSubaccounts = true
        #expect(f.model.registerRows.count == 2)      // still shown
        #expect(f.model.registerRows.map(\.runningBalance) == [100, 100])  // but weightless
    }

    @Test("Only an account with children is offered subaccounts")
    func onlyOfferedWhereItMeansSomething() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.parent
        #expect(f.model.selectedAccountHasChildren)
        f.model.selectedAccountID = f.child
        #expect(!f.model.selectedAccountHasChildren)
        f.model.selectedAccountID = nil
        #expect(!f.model.selectedAccountHasChildren)
    }

    @Test("Closing a book forgets the setting")
    func resetOnClose() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.parent
        f.model.registerIncludesSubaccounts = true
        f.model.close()
        #expect(!f.model.registerIncludesSubaccounts)
    }
}
