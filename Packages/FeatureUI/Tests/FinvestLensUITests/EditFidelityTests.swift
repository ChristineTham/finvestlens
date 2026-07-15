//
//  EditFidelityTests.swift
//  FinvestLens — FeatureUI
//
//  What an edit must **not** destroy, and what voiding must and must not move.
//
//  These pin three bugs found auditing the register against GnuCash (July 2026).
//  Each was invisible to the balance checks: a transaction whose *values* still
//  balance can still have had its share count, its memos, or its contribution to
//  the running balance silently rewritten.
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
@Suite("Edit fidelity")
struct EditFidelityTests {

    /// Builds a 100-share / $1,000 CBA buy and returns (model, txnID, sharesID).
    private func bookWithHolding() throws -> (AppModel, URL, GncGUID, GncGUID) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)

        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "CBA", smallestFraction: 10_000)
        let shares = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
        let cash = try #require(model.addAccount(name: "Cash", type: .bank))
        let txn = try model.addTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_000), description: "Buy CBA",
            currency: .aud,
            splits: [SplitInput(accountID: shares, value: dec("1000"),
                                quantity: dec("100"), memo: "buy 100"),
                     SplitInput(accountID: cash, value: dec("-1000"), memo: "settlement")])
        return (model, url, txn, shares)
    }

    /// The actual bug site: the editor's row type is what the sheet loads into
    /// and saves out of, and it used to carry neither quantity nor memo — so
    /// every save rebuilt the split without them. Tests that go straight to
    /// `updateTransaction` cannot see this; the loss happens in the view layer.
    @Test("An editor row carries the split's quantity and memo through untouched")
    func editableSplitRoundTripsQuantityAndMemo() throws {
        let account = GncGUID.random()
        let original = SplitInput(accountID: account, value: dec("1000"),
                                  quantity: dec("100"), memo: "buy 100")

        let roundTripped = EditableSplit(original).asInput

        #expect(roundTripped.accountID == account)
        #expect(roundTripped.value == dec("1000"))
        #expect(roundTripped.quantity == dec("100"), "share count survives the editor row")
        #expect(roundTripped.memo == "buy 100", "memo survives the editor row")
    }

    /// A cash split has no independent quantity; the row must keep it `nil` so
    /// the engine keeps quantity tied to the value.
    @Test("An editor row keeps a cash split's quantity nil")
    func editableSplitKeepsCashQuantityNil() throws {
        let input = SplitInput(accountID: GncGUID.random(), value: dec("100"))
        #expect(EditableSplit(input).asInput.quantity == nil)
    }

    /// The model half of the same round-trip: `editData` out, `updateTransaction`
    /// back in, no change between. This half was always correct — the loss was
    /// entirely in the editor row above — but it is the contract that row relies
    /// on, so it is worth holding still.
    @Test("editData → updateTransaction preserves share count and memos")
    func modelRoundTripPreservesQuantityAndMemo() throws {
        let (model, url, txn, shares) = try bookWithHolding()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        // Exactly what the editor sheet sends back: read via editData, write via
        // updateTransaction, with no user change in between.
        let edit = try #require(model.editData(forTransaction: txn))
        try model.updateTransaction(id: txn, date: edit.date, description: edit.description,
                                    currency: edit.currency, splits: edit.splits, tags: edit.tags)

        let split = try #require(model.book?.transaction(with: txn)?.splits
            .first { $0.account?.guid == shares })
        #expect(split.quantity == dec("100"))
        #expect(split.value == dec("1000"))
        #expect(split.memo == "buy 100")
        let cashSplit = try #require(model.book?.transaction(with: txn)?.splits
            .first { $0.account?.guid != shares })
        #expect(cashSplit.memo == "settlement")
    }

    /// Repricing a holding changes the value, not the number of shares.
    @Test("Editing the value of a security split leaves the share count alone")
    func editingValueKeepsShares() throws {
        let (model, url, txn, shares) = try bookWithHolding()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let edit = try #require(model.editData(forTransaction: txn))
        let repriced = edit.splits.map { input -> SplitInput in
            var copy = input
            copy.value = input.value > 0 ? dec("1200") : dec("-1200")
            return copy
        }
        try model.updateTransaction(id: txn, date: edit.date, description: edit.description,
                                    currency: edit.currency, splits: repriced)

        let split = try #require(model.book?.transaction(with: txn)?.splits
            .first { $0.account?.guid == shares })
        #expect(split.value == dec("1200"))
        #expect(split.quantity == dec("100"), "still 100 shares — only the value changed")
    }

    /// A plain cash split has no independent quantity, so editing the amount
    /// must carry the quantity with it (quantity `nil` means "same as value").
    @Test("Editing a cash split's amount moves its quantity too")
    func cashSplitQuantityFollowsValue() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        let txn = try model.addTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_000), description: "Pay",
            currency: .aud,
            splits: [SplitInput(accountID: bank, value: dec("100")),
                     SplitInput(accountID: income, value: dec("-100"))])

        let edit = try #require(model.editData(forTransaction: txn))
        let doubled = edit.splits.map { input -> SplitInput in
            var copy = input
            copy.value = input.value * 2
            return copy
        }
        try model.updateTransaction(id: txn, date: edit.date, description: edit.description,
                                    currency: edit.currency, splits: doubled)

        let split = try #require(model.book?.transaction(with: txn)?.splits
            .first { $0.account?.guid == bank })
        #expect(split.value == dec("200"))
        #expect(split.quantity == dec("200"))
    }

    /// The register's running balance is the same number the sidebar shows.
    @Test("A voided transaction leaves the register agreeing with the balance")
    func voidedSplitsLeaveRegisterAgreeingWithBalance() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        model.addTransfer(from: income, to: bank, amount: dec("100"),
                          date: Date(timeIntervalSince1970: 1_700_000_000), description: "Pay 1")
        let second = try #require(model.addTransfer(from: income, to: bank, amount: dec("50"),
                                                    date: Date(timeIntervalSince1970: 1_700_086_400),
                                                    description: "Pay 2"))
        model.voidTransaction(second)
        model.selectedAccountID = bank

        let account = try #require(model.book?.account(with: bank))
        let balance = try #require(model.book?.balance(of: account).amount)
        #expect(balance == dec("100"), "voided split is out of the balance")
        #expect(model.registerRows.last?.runningBalance == balance,
                "…and out of the register's running balance")
        // The row still shows, with its amount and a 'v' — voiding hides nothing.
        #expect(model.registerRows.count == 2)
        #expect(model.registerRows.last?.reconcile == "v")
        #expect(model.accountTree.first { $0.name == "Bank" }?.balance == dec("100"))
    }

    @Test("Unvoid restores a voided transaction to the balance")
    func unvoidRestoresBalance() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        let txn = try #require(model.addTransfer(from: income, to: bank, amount: dec("100"),
                                                 date: Date(timeIntervalSince1970: 1_700_000_000),
                                                 description: "Pay"))
        model.selectedAccountID = bank

        model.voidTransaction(txn)
        #expect(model.isVoided(txn))
        #expect(model.registerRows.last?.runningBalance == 0)

        model.unvoidTransaction(txn)
        #expect(!model.isVoided(txn))
        #expect(model.registerRows.last?.runningBalance == dec("100"))
        #expect(model.registerRows.last?.reconcile == "n")
    }

    /// A stray click on the R column used to un-void a transaction one split
    /// at a time, which silently moved the balance.
    @Test("Clicking the R column does not un-void a transaction")
    func cyclingLeavesVoidedAlone() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        let txn = try #require(model.addTransfer(from: income, to: bank, amount: dec("100"),
                                                 date: Date(timeIntervalSince1970: 1_700_000_000),
                                                 description: "Pay"))
        model.voidTransaction(txn)
        model.selectedAccountID = bank

        let rowID = try #require(model.registerRows.last?.id)
        model.cycleReconcileState(splitID: rowID)
        #expect(model.isVoided(txn), "still voided")
        #expect(model.registerRows.last?.runningBalance == 0, "balance did not move")

        // Frozen is likewise not part of the n → c → y cycle.
        model.unvoidTransaction(txn)
        model.setReconcileState(splitID: rowID, to: .frozen)
        model.cycleReconcileState(splitID: rowID)
        #expect(model.registerRows.last?.reconcile == "f")
    }

    /// The normal cycle still works.
    @Test("The R column still cycles n → c → y → n")
    func cycleStillWorks() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        _ = model.addTransfer(from: income, to: bank, amount: dec("100"),
                              date: Date(timeIntervalSince1970: 1_700_000_000), description: "Pay")
        model.selectedAccountID = bank

        let rowID = try #require(model.registerRows.last?.id)
        #expect(model.registerRows.last?.reconcile == "n")
        model.cycleReconcileState(splitID: rowID)
        #expect(model.registerRows.last?.reconcile == "c")
        model.cycleReconcileState(splitID: rowID)
        #expect(model.registerRows.last?.reconcile == "y")
        model.cycleReconcileState(splitID: rowID)
        #expect(model.registerRows.last?.reconcile == "n")
    }
}
