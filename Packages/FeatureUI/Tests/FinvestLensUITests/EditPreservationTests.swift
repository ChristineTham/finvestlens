//
//  EditPreservationTests.swift
//  FinvestLens — FeatureUI
//
//  What a save must not destroy.
//
//  A split carries more than the editor shows: reconcile state and date, its
//  own identity, a per-split action, preserved KVP slots. The editor rebuilt
//  every split on save, so each of those was replaced by a constructor default
//  — and because the *values* still balanced, nothing downstream could notice.
//  On the reference book that silently un-reconciled any transaction anyone
//  edited: 34,939 of 46,553 transactions have a reconciled or cleared split.
//
//  These tests are the check no balance assertion can make. The register bug
//  they descend from (share counts reset to the dollar value) is pinned in
//  `EditingTests`; this suite covers everything else hanging off a split.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Edit preservation")
struct EditPreservationTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let txn: Transaction
        let bank: Account
        let food: Account
    }

    /// A reconciled two-split transaction carrying every field the editor does
    /// not show, so that a save which forgets one of them fails here.
    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)

        let bankID = try #require(model.addAccount(name: "Bank", type: .bank))
        let foodID = try #require(model.addAccount(name: "Food", type: .expense))
        let book = try #require(model.book)
        let bank = try #require(book.account(with: bankID))
        let food = try #require(book.account(with: foodID))

        let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 0),
                              dateEntered: Date(timeIntervalSince1970: 900_000),
                              description: "Groceries", notes: "weekly shop")
        txn.addSplit(Split(account: bank, value: -50, reconcileState: .reconciled,
                           reconcileDate: Date(timeIntervalSince1970: 500_000),
                           memo: "card", action: "Withdrawal"))
        txn.addSplit(Split(account: food, value: 50, reconcileState: .cleared,
                           memo: "veg", action: "Buy"))
        book.addTransaction(txn)
        return Fixture(model: model, url: url, txn: txn, bank: bank, food: food)
    }

    /// Re-saves a transaction with one field changed and nothing else touched —
    /// the edit a user makes to fix a typo.
    private func resave(_ f: Fixture, description: String = "Groceries (fixed)") throws {
        let edit = try #require(f.model.editData(forTransaction: f.txn.guid))
        _ = try f.model.updateTransaction(id: f.txn.guid, date: edit.date,
                                          description: description,
                                          currency: edit.currency, splits: edit.splits)
    }

    /// The one that matters: a reconciled book must survive being edited. This
    /// is the assertion that stands in for the status-bar Reconciled balance,
    /// which GnuCash puts at $57,909.82 on the reference book and which an edit
    /// would otherwise quietly walk down.
    @Test("Editing a transaction leaves reconcile state alone")
    func reconcileStateSurvives() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        try resave(f)
        #expect(f.txn.splits.map(\.reconcileState) == [.reconciled, .cleared])
    }

    @Test("Editing a transaction leaves the reconcile date alone")
    func reconcileDateSurvives() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        try resave(f)
        #expect(f.txn.splits[0].reconcileDate == Date(timeIntervalSince1970: 500_000))
    }

    /// Splits are identified by GUID across a GnuCash round-trip. Minting new
    /// ones on every save makes an edited transaction a different transaction
    /// to anything holding a reference to its legs.
    @Test("Editing a transaction preserves split identity")
    func splitGUIDsSurvive() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let before = f.txn.splits.map(\.guid)
        try resave(f)
        #expect(f.txn.splits.map(\.guid) == before)
    }

    @Test("Editing a transaction preserves per-split action and memo")
    func actionAndMemoSurvive() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        try resave(f)
        #expect(f.txn.splits.map(\.action) == ["Withdrawal", "Buy"])
        #expect(f.txn.splits.map(\.memo) == ["card", "veg"])
    }

    @Test("Editing a transaction preserves notes and preserved slots")
    func notesAndSlotsSurvive() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.txn.splits[0].kvp["some-importer-slot"] = .string("keep me")
        try resave(f)
        #expect(f.txn.notes == "weekly shop")
        #expect(f.txn.splits[0].kvp["some-importer-slot"] == .string("keep me"))
    }

    /// `dateEntered` is when the transaction was entered, not when it was last
    /// touched — and the register sorts by it. Every transaction in the
    /// reference book has a `dateEntered` later than its posting date, so
    /// assigning one to the other on save was visible on all 46,553 of them.
    @Test("Editing a transaction does not rewrite the entry date")
    func dateEnteredSurvives() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        try resave(f)
        #expect(f.txn.dateEntered == Date(timeIntervalSince1970: 900_000))
    }

    /// Changing the posting date is a real edit and must still take effect —
    /// the fix above must not be "stop writing dates".
    @Test("Changing the posting date still moves the posting date")
    func datePostedStillChanges() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let edit = try #require(f.model.editData(forTransaction: f.txn.guid))
        let moved = Date(timeIntervalSince1970: 86_400)
        _ = try f.model.updateTransaction(id: f.txn.guid, date: moved,
                                          description: edit.description,
                                          currency: edit.currency, splits: edit.splits)
        #expect(f.txn.datePosted == moved)
        #expect(f.txn.dateEntered == Date(timeIntervalSince1970: 900_000))
    }

    /// Reuse is keyed on the split a row came from, so a genuinely new leg must
    /// still get a fresh split — and must not inherit anyone's reconcile state.
    @Test("A newly added leg is a new split, unreconciled")
    func addedLegIsNew() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let book = try #require(f.model.book)
        let feesID = try #require(f.model.addAccount(name: "Fees", type: .expense))
        let before = Set(f.txn.splits.map(\.guid))

        var splits = try #require(f.model.editData(forTransaction: f.txn.guid)).splits
        splits[1].value = 45
        splits.append(SplitInput(accountID: feesID, value: 5, action: "Fee"))
        _ = try f.model.updateTransaction(id: f.txn.guid, date: f.txn.datePosted,
                                          description: "Groceries",
                                          currency: .aud, splits: splits)

        #expect(f.txn.splits.count == 3)
        let added = try #require(f.txn.splits.first { !before.contains($0.guid) })
        #expect(added.account === book.account(with: feesID))
        #expect(added.reconcileState == .notReconciled)
        #expect(added.action == "Fee")
        // The two originals kept their state through a structural change.
        #expect(f.txn.splits[0].reconcileState == .reconciled)
        #expect(f.txn.splits[1].reconcileState == .cleared)
    }

    /// Removing a leg must actually remove it, not resurrect it by GUID.
    @Test("A removed leg stays removed")
    func removedLegStaysRemoved() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let feesID = try #require(f.model.addAccount(name: "Fees", type: .expense))
        var splits = try #require(f.model.editData(forTransaction: f.txn.guid)).splits
        let droppedGUID = try #require(splits[1].splitID)
        splits[1] = SplitInput(accountID: feesID, value: 50, action: "Fee")
        _ = try f.model.updateTransaction(id: f.txn.guid, date: f.txn.datePosted,
                                          description: "Groceries",
                                          currency: .aud, splits: splits)
        #expect(f.txn.splits.count == 2)
        #expect(!f.txn.splits.map(\.guid).contains(droppedGUID))
    }

    /// The editor's own round-trip: what the sheet loads and hands back must be
    /// what it was given. `EditableSplit` is the type that forgets things.
    @Test("The editor row round-trips every split field")
    func editableSplitRoundTrips() throws {
        let input = SplitInput(splitID: .random(), accountID: .random(), value: 100,
                               quantity: 25, memo: "m", action: "Buy")
        let out = EditableSplit(input).asInput
        #expect(out.splitID == input.splitID)
        #expect(out.accountID == input.accountID)
        #expect(out.value == input.value)
        #expect(out.quantity == input.quantity)
        #expect(out.memo == input.memo)
        #expect(out.action == input.action)
    }
}
