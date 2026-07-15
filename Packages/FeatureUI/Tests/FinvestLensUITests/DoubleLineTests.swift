//
//  DoubleLineTests.swift
//  FinvestLens — FeatureUI
//
//  Transaction notes and per-split memo/action, which the engine has always
//  stored and round-tripped and the UI has never shown. 18,641 of the 46,553
//  transactions in the reference book carry notes; 10,876 splits carry a memo
//  and 280 an action. None of it was reachable.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Double line")
struct DoubleLineTests {

    private func makeModel() throws -> (AppModel, URL, bank: GncGUID, food: GncGUID) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        return (model, url, bank, food)
    }

    @Test("A new transaction can be given notes, and they come back")
    func notesRoundTripThroughTheEditor() throws {
        let (model, url, bank, food) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let id = try model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "Shop", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -10, memo: "card", action: "Withdrawal"),
                     SplitInput(accountID: food, value: 10, memo: "veg", action: "Buy")],
            notes: "reimbursable")

        let edit = try #require(model.editData(forTransaction: id))
        #expect(edit.notes == "reimbursable")
        #expect(edit.splits.map(\.memo) == ["card", "veg"])
        #expect(edit.splits.map(\.action) == ["Withdrawal", "Buy"])
    }

    @Test("Notes, memo and action can all be edited")
    func fieldsAreEditable() throws {
        let (model, url, bank, food) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let id = try model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "Shop", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -10),
                     SplitInput(accountID: food, value: 10)],
            notes: "first")

        var splits = try #require(model.editData(forTransaction: id)).splits
        splits[0].memo = "new memo"
        splits[0].action = "Cheque"
        _ = try model.updateTransaction(id: id, date: Date(timeIntervalSince1970: 0),
                                        description: "Shop", currency: .aud,
                                        splits: splits, notes: "second")

        let after = try #require(model.editData(forTransaction: id))
        #expect(after.notes == "second")
        #expect(after.splits[0].memo == "new memo")
        #expect(after.splits[0].action == "Cheque")
    }

    /// Passing no notes must mean "leave them alone", not "clear them" — the
    /// callers that edit a transaction without touching notes (the rules engine,
    /// the importer) go through this same method.
    @Test("Omitting notes leaves existing notes alone")
    func omittedNotesArePreserved() throws {
        let (model, url, bank, food) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let id = try model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "Shop", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -10),
                     SplitInput(accountID: food, value: 10)],
            notes: "keep me")

        let edit = try #require(model.editData(forTransaction: id))
        _ = try model.updateTransaction(id: id, date: edit.date, description: "Shop again",
                                        currency: .aud, splits: edit.splits)
        #expect(try #require(model.editData(forTransaction: id)).notes == "keep me")
    }

    /// The register's second line is the three fields joined, skipping whatever
    /// is empty — which on most rows is all of them.
    @Test("The second line joins only the fields that have something to say")
    func secondLineComposition() {
        func row(notes: String = "", memo: String = "", action: String = "") -> RegisterRow {
            RegisterRow(id: .random(), date: Date(), dateEntered: Date(), number: "",
                        description: "d", transfer: "t", reconcile: "n",
                        memo: memo, notes: notes, action: action,
                        amount: 0, runningBalance: 0)
        }
        #expect(row().secondLine == "")
        #expect(row(notes: "n").secondLine == "n")
        #expect(row(memo: "m").secondLine == "m")
        #expect(row(notes: "n", memo: "m", action: "a").secondLine == "n · m · a")
        #expect(row(notes: "n", action: "a").secondLine == "n · a")
    }

    /// The register row has to carry the notes for the second line to show them.
    @Test("Register rows carry the transaction's notes and the split's action")
    func registerRowCarriesNotes() throws {
        let (model, url, bank, food) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        _ = try model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "Shop", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -10, memo: "card", action: "Withdrawal"),
                     SplitInput(accountID: food, value: 10)],
            notes: "reimbursable")

        model.selectedAccountID = bank
        let row = try #require(model.registerRows.first)
        #expect(row.notes == "reimbursable")
        #expect(row.memo == "card")
        #expect(row.action == "Withdrawal")
        #expect(row.secondLine == "reimbursable · card · Withdrawal")
    }
}
