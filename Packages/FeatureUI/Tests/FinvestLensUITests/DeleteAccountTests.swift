//
//  DeleteAccountTests.swift
//  FinvestLens — FeatureUI
//
//  Deleting an account that has been used.
//
//  Delete used to be refused outright for any account with a posting or a
//  child, which on a real book is nearly all of them — the button was simply
//  hidden, with nothing to say why. GnuCash instead asks where the contents
//  should go. That makes this the one account operation that moves real money
//  between accounts, so what it must never do is lose a split or change what
//  one is worth.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Delete account")
struct DeleteAccountTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let book: Book
        let undo: UndoManager
    }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        let undo = UndoManager()
        model.undoManager = undo
        try model.newDocument(at: url)
        return Fixture(model: model, url: url, book: try #require(model.book), undo: undo)
    }

    private func post(_ f: Fixture, _ from: GncGUID, _ to: GncGUID,
                      _ amount: Decimal, day: Int = 0) throws {
        _ = try f.model.addTransaction(
            date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
            description: "t", currency: .aud,
            splits: [SplitInput(accountID: from, value: -amount),
                     SplitInput(accountID: to, value: amount)])
    }

    @Test("An empty account needs no target and just goes")
    func emptyAccount() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let id = try #require(f.model.addAccount(name: "Unused", type: .expense))
        #expect(f.model.deletionPlan(for: id)?.isUnencumbered == true)
        try f.model.deleteAccount(id)
        #expect(f.book.account(with: id) == nil)
    }

    /// The case the old code refused: an account someone actually used.
    @Test("An account with postings is deletable once they have somewhere to go")
    func postingsMove() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let bank = try #require(f.model.addAccount(name: "Bank", type: .bank))
        let old = try #require(f.model.addAccount(name: "Old", type: .expense))
        let new = try #require(f.model.addAccount(name: "New", type: .expense))
        try post(f, bank, old, 30)
        try post(f, bank, old, 12)

        #expect(f.model.deletionPlan(for: old)?.isUnencumbered == false)
        #expect(f.model.deletionPlan(for: old)?.splitCount == 2)

        try f.model.deleteAccount(old, movingTransactionsTo: new)

        #expect(f.book.account(with: old) == nil)
        let target = try #require(f.book.account(with: new))
        #expect(f.book.splits(for: target).count == 2)
        // The money did not change on the way across.
        #expect(f.book.balance(of: target).amount == 42)
    }

    /// The invariant that matters most: the book still balances, and no split
    /// was dropped on the floor.
    @Test("Moving postings keeps every split and leaves the book balanced")
    func nothingIsLost() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let bank = try #require(f.model.addAccount(name: "Bank", type: .bank))
        let old = try #require(f.model.addAccount(name: "Old", type: .expense))
        let new = try #require(f.model.addAccount(name: "New", type: .expense))
        try post(f, bank, old, 30)
        try post(f, bank, new, 5)

        let splitsBefore = f.book.transactions.flatMap(\.splits).count
        try f.model.deleteAccount(old, movingTransactionsTo: new)

        let splitsAfter = f.book.transactions.flatMap(\.splits)
        let allBalanced = f.book.transactions.filter { !$0.isBalanced }.isEmpty
        let allAttached = splitsAfter.filter { $0.account == nil }.isEmpty
        #expect(splitsAfter.count == splitsBefore)
        #expect(allBalanced)
        #expect(allAttached)
    }

    @Test("Refuses to delete an account with postings and no target")
    func postingsNeedTarget() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let bank = try #require(f.model.addAccount(name: "Bank", type: .bank))
        let old = try #require(f.model.addAccount(name: "Old", type: .expense))
        try post(f, bank, old, 30)
        #expect(throws: AppModel.AccountDeletionError.transactionsNeedTarget) {
            try f.model.deleteAccount(old)
        }
        // And it is still there, untouched.
        let survivor = try #require(f.book.account(with: old))
        #expect(f.book.splits(for: survivor).count == 1)
    }

    @Test("Children are reparented, keeping their own postings")
    func childrenMove() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let bank = try #require(f.model.addAccount(name: "Bank", type: .bank))
        let parent = try #require(f.model.addAccount(name: "Parent", type: .expense))
        let child = try #require(f.model.addAccount(name: "Child", type: .expense,
                                                    parentID: parent))
        let newParent = try #require(f.model.addAccount(name: "Elsewhere", type: .expense))
        try post(f, bank, child, 17)

        let plan = try #require(f.model.deletionPlan(for: parent))
        #expect(plan.childCount == 1)
        #expect(plan.splitCount == 0)          // the parent itself holds nothing
        #expect(plan.descendantSplitCount == 1) // but its child does

        try f.model.deleteAccount(parent, movingChildrenTo: newParent)

        #expect(f.book.account(with: parent) == nil)
        let moved = try #require(f.book.account(with: child))
        #expect(moved.parent?.guid == newParent)
        #expect(f.book.balance(of: moved).amount == 17)
    }

    @Test("Refuses to delete a parent with no home for its children")
    func childrenNeedTarget() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let parent = try #require(f.model.addAccount(name: "Parent", type: .expense))
        _ = try #require(f.model.addAccount(name: "Child", type: .expense, parentID: parent))
        #expect(throws: AppModel.AccountDeletionError.childrenNeedTarget) {
            try f.model.deleteAccount(parent)
        }
        #expect(f.book.account(with: parent) != nil)
    }

    /// Moving the contents into the subtree being deleted would delete them
    /// with it — the move has to land outside.
    @Test("Refuses a target inside the account being deleted")
    func targetInsideSubtree() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let bank = try #require(f.model.addAccount(name: "Bank", type: .bank))
        let parent = try #require(f.model.addAccount(name: "Parent", type: .expense))
        let child = try #require(f.model.addAccount(name: "Child", type: .expense,
                                                    parentID: parent))
        try post(f, bank, parent, 5)

        #expect(throws: AppModel.AccountDeletionError.targetIsSelfOrDescendant) {
            try f.model.deleteAccount(parent, movingTransactionsTo: child,
                                      movingChildrenTo: child)
        }
        #expect(f.book.account(with: parent) != nil)
        #expect(f.book.account(with: child) != nil)
    }

    /// A quantity means "so many of the account's commodity". Moving 100 BHP
    /// shares into an AUD account would silently make them 100 dollars.
    @Test("Refuses to move postings to an account of another commodity")
    func commodityMismatch() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let aud = try #require(f.model.addAccount(name: "AUD Bank", type: .bank, commodity: .aud))
        let usd = try #require(f.model.addAccount(name: "USD Bank", type: .bank, commodity: .usd))
        let other = try #require(f.model.addAccount(name: "Other AUD", type: .bank, commodity: .aud))
        try post(f, aud, other, 10)

        _ = try f.model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "usd",
                                       currency: .usd,
                                       splits: [SplitInput(accountID: usd, value: 5),
                                                SplitInput(accountID: other, value: -5)])

        #expect(throws: AppModel.AccountDeletionError.targetCommodityDiffers) {
            try f.model.deleteAccount(usd, movingTransactionsTo: other)
        }
        // And the mismatched account is not offered in the first place.
        #expect(!f.model.transactionTargets(forDeleting: usd).contains { $0.id == other })
    }

    @Test("Targets exclude the account itself and its descendants")
    func targetsExcludeSubtree() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let parent = try #require(f.model.addAccount(name: "Parent", type: .expense))
        let child = try #require(f.model.addAccount(name: "Child", type: .expense,
                                                    parentID: parent))
        _ = try #require(f.model.addAccount(name: "Outside", type: .expense))

        let txnTargets = f.model.transactionTargets(forDeleting: parent).map(\.id)
        #expect(!txnTargets.contains(parent))
        #expect(!txnTargets.contains(child))
        let childTargets = f.model.childTargets(forDeleting: parent).map(\.id)
        #expect(!childTargets.contains(parent))
        #expect(!childTargets.contains(child))
    }

    @Test("Deleting the selected account clears the selection")
    func clearsSelection() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let id = try #require(f.model.addAccount(name: "Gone", type: .expense))
        f.model.selectedAccountID = id
        try f.model.deleteAccount(id)
        #expect(f.model.selectedAccountID == nil)
    }

    /// A delete that moved money is one Undo, like every other edit.
    ///
    /// The stack is cleared after the setup on purpose: `UndoManager` groups by
    /// event loop, and a test has no event loop, so every registration up to
    /// here would otherwise coalesce into one group and a single undo would
    /// unwind the whole book back to empty.
    @Test("Undo puts the account and its postings back")
    func undoRestores() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let bank = try #require(f.model.addAccount(name: "Bank", type: .bank))
        let old = try #require(f.model.addAccount(name: "Old", type: .expense))
        let new = try #require(f.model.addAccount(name: "New", type: .expense))
        try post(f, bank, old, 30)
        f.undo.removeAllActions()

        try f.model.deleteAccount(old, movingTransactionsTo: new)
        #expect(f.model.book?.account(with: old) == nil)

        f.undo.undo()
        let book = try #require(f.model.book)
        let restored = try #require(book.account(with: old))
        #expect(book.balance(of: restored).amount == 30)
        let target = try #require(book.account(with: new))
        #expect(book.balance(of: target).amount == 0)
    }

    @Test("Redo deletes it again")
    func redoDeletes() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let bank = try #require(f.model.addAccount(name: "Bank", type: .bank))
        let old = try #require(f.model.addAccount(name: "Old", type: .expense))
        let new = try #require(f.model.addAccount(name: "New", type: .expense))
        try post(f, bank, old, 30)
        f.undo.removeAllActions()

        try f.model.deleteAccount(old, movingTransactionsTo: new)
        f.undo.undo()
        f.undo.redo()

        let book = try #require(f.model.book)
        #expect(book.account(with: old) == nil)
        let target = try #require(book.account(with: new))
        #expect(book.balance(of: target).amount == 30)
    }
}

/// The dialog's own wording. Worth pinning: the first attempt used
/// `^[\(n) split](inflect: true)`, which only resolves for a localized string
/// resource — interpolated into a `Text` it renders the markup, and the sheet
/// read "^[2312 split](inflect: true) posted to “ANZ Access”".
@MainActor
@Suite("Delete account wording")
struct DeleteAccountWordingTests {

    @Test("Counts are pluralised and grouped, with no markup left in them")
    func counts() {
        #expect(DeleteAccountSheet.count(1, "split") == "1 split")
        #expect(DeleteAccountSheet.count(0, "split") == "0 splits")
        #expect(DeleteAccountSheet.count(2, "subaccount") == "2 subaccounts")
        // The real one, from the reference book's ANZ Access.
        #expect(DeleteAccountSheet.count(2312, "split") == "2,312 splits")
        #expect(!DeleteAccountSheet.count(2312, "split").contains("inflect"))
        #expect(!DeleteAccountSheet.count(2312, "split").contains("^["))
    }
}
