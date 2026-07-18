//
//  TransactionActionsTests.swift
//  FinvestLens — FeatureUI
//
//  Reaching the register's operations from the menu bar.
//
//  Every per-transaction operation was context-menu-only: no menu-bar items, no
//  keyboard shortcuts, and in the Journal and General Ledger styles no way to
//  reach any of them but Edit. The menu bar cannot see a register's `@State`,
//  so the selection had to move onto the model — and once it has, the same
//  actions view serves the context menus and the menu bar, which is what stops
//  the two lists drifting apart again.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Transaction actions")
struct TransactionActionsTests {

    private func makeModel() throws -> (AppModel, URL, bank: GncGUID, food: GncGUID, txn: GncGUID) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let txn = try model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "Shop", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -10),
                     SplitInput(accountID: food, value: 10)])
        return (model, url, bank, food, txn)
    }

    @Test("A check is drawn on the outflow account, spelled out for the payee (FR-REG-11)")
    func checkPrinting() throws {
        let (model, url, _, _, txn) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let check = try #require(model.checkData(forTransaction: txn))
        #expect(check.payee == "Shop")           // the transaction description
        #expect(check.amount == 10)              // the −10 bank outflow, as a positive
        #expect(check.drawnOn == "Bank")
        #expect(check.amountInWords == "Ten and 00/100")
    }

    /// The link the menu bar needs: from a selected row to the transaction the
    /// commands act on.
    @Test("A selected row resolves to its transaction")
    func selectionResolves() throws {
        let (model, url, bank, _, txn) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        #expect(!model.hasSelectedTransaction)
        #expect(model.selectedTransactionID == nil)

        model.selectedAccountID = bank
        let row = try #require(model.registerRows.first)
        model.selectedSplitID = row.id

        #expect(model.hasSelectedTransaction)
        #expect(model.selectedTransactionID == txn)
    }

    @Test("Selecting nothing leaves the commands with nothing to act on")
    func noSelection() throws {
        let (model, url, _, _, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.selectedSplitID = nil
        #expect(!model.hasSelectedTransaction)
    }

    /// A stale selection must not resolve to something. Deleting the selected
    /// transaction leaves the id behind, and a menu that still acted on it would
    /// be acting on nothing.
    @Test("A selection pointing at a deleted transaction resolves to nothing")
    func staleSelection() throws {
        let (model, url, bank, _, txn) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.selectedAccountID = bank
        model.selectedSplitID = try #require(model.registerRows.first).id
        model.deleteTransaction(txn)
        #expect(!model.hasSelectedTransaction)
    }

    /// A journal row can be a heading, which stands for the transaction and has
    /// no split of its own — the operations reach it through any leg.
    @Test("Any leg of a transaction stands for the whole transaction")
    func anySplitResolves() throws {
        let (model, url, _, _, txn) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let splitID = try #require(model.anySplitID(ofTransaction: txn))
        #expect(model.transactionID(ofSplit: splitID) == txn)
    }

    @Test("An unknown transaction has no leg to act through")
    func anySplitOfUnknown() throws {
        let (model, url, _, _, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        #expect(model.anySplitID(ofTransaction: .random()) == nil)
    }

    /// The editor is opened by setting this, so a menu command and a
    /// double-click are the same code path.
    @Test("Opening the editor is model state, not view state")
    func editorIsModelState() throws {
        let (model, url, _, _, txn) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        #expect(model.editingTransactionID == nil)
        model.editingTransactionID = txn
        #expect(model.editingTransactionID == txn)
    }

    /// The operations the menu offers must all work through a split id, since
    /// that is all the menu has.
    @Test("Every offered operation acts through the selected row")
    func operationsWorkFromSelection() throws {
        let (model, url, bank, _, txn) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.selectedAccountID = bank
        model.selectedSplitID = try #require(model.registerRows.first).id
        let splitID = try #require(model.selectedSplitID)

        // Reconcile state, jump, void and duplicate all resolve from the row.
        model.setReconcileState(splitID: splitID, to: .cleared)
        #expect(model.reconcileState(ofSplit: splitID) == .cleared)
        #expect(model.otherAccountID(ofSplit: splitID) != nil)

        model.voidTransaction(txn)
        #expect(model.isVoided(txn))
        model.unvoidTransaction(txn)
        #expect(!model.isVoided(txn))

        let before = model.book?.transactions.count ?? 0
        model.duplicateTransaction(txn)
        #expect(model.book?.transactions.count == before + 1)
    }
}
