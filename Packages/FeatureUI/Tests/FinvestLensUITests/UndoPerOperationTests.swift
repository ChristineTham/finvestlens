//
//  UndoPerOperationTests.swift
//  FinvestLens — FeatureUI
//
//  Every mutation has to survive a ⌘Z / ⌘⇧Z round-trip. Undo is pre-capture:
//  an edit records what it is about to change before changing it, so there is
//  no maintained baseline to fall out of step. These tests pin that down one
//  operation at a time — the register paths, which snapshot only the touched
//  transactions, and the structural paths, which snapshot the book.
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

/// A book with two accounts and an undo manager, wound back to a clean slate.
///
/// In tests every mutation lands in one implicit event group (there is no run
/// loop to close it), so the set-up is cleared off the stack to leave undo
/// pointing at the operation under test.
@MainActor
private struct Fixture {
    let model = AppModel()
    let undo = UndoManager()
    let bank: GncGUID
    let food: GncGUID
    let url: URL

    init() throws {
        url = tempURL()
        model.undoManager = undo
        try model.newDocument(at: url)
        bank = try #require(model.addAccount(name: "Bank", type: .bank))
        food = try #require(model.addAccount(name: "Food", type: .expense))
        undo.removeAllActions()
    }

    /// Adds a two-split transaction and clears it off the undo stack.
    @discardableResult
    func seedTransaction(_ description: String = "Lunch", amount: Decimal = 25) throws -> GncGUID {
        let id = try model.addTransaction(
            date: Date(), description: description, currency: .aud,
            splits: [SplitInput(accountID: bank, value: -amount),
                     SplitInput(accountID: food, value: amount)])
        undo.removeAllActions()
        return id
    }

    func tearDown() {
        model.close()
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
@Suite("Undo / redo — transaction operations")
struct UndoTransactionOperationTests {

    @Test("Add transaction undoes to nothing and redoes back")
    func addTransaction() throws {
        let f = try Fixture()
        defer { f.tearDown() }

        let id = try f.model.addTransaction(
            date: Date(), description: "Lunch", currency: .aud,
            splits: [SplitInput(accountID: f.bank, value: -25),
                     SplitInput(accountID: f.food, value: 25)])
        #expect(f.model.book?.transactions.count == 1)

        f.undo.undo()
        #expect(f.model.book?.transactions.isEmpty == true)

        f.undo.redo()
        #expect(f.model.book?.transaction(with: id)?.transactionDescription == "Lunch")
        #expect(f.model.book?.transaction(with: id)?.splits.count == 2)
    }

    @Test("Edit transaction restores the previous fields and splits")
    func updateTransaction() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()

        _ = try f.model.updateTransaction(
            id: id, date: Date(), description: "Dinner", currency: .aud,
            splits: [SplitInput(accountID: f.bank, value: -40),
                     SplitInput(accountID: f.food, value: 40)])
        #expect(f.model.book?.transaction(with: id)?.transactionDescription == "Dinner")

        f.undo.undo()
        let restored = try #require(f.model.book?.transaction(with: id))
        #expect(restored.transactionDescription == "Lunch")
        #expect(restored.splits.map(\.value).sorted() == [-25, 25])

        f.undo.redo()
        #expect(f.model.book?.transaction(with: id)?.splits.map(\.value).sorted() == [-40, 40])
    }

    @Test("An unknown account throws without rewriting the transaction")
    func updateTransactionRejectsUnknownAccount() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()

        #expect(throws: TransactionEntryError.unknownAccount) {
            try f.model.updateTransaction(
                id: id, date: Date(), description: "Dinner", currency: .aud,
                splits: [SplitInput(accountID: f.bank, value: -40),
                         SplitInput(accountID: GncGUID.random(), value: 40)])
        }
        // The edit resolves accounts up front, so a bad split leaves the
        // transaction exactly as it was rather than half-rewritten.
        let untouched = try #require(f.model.book?.transaction(with: id))
        #expect(untouched.transactionDescription == "Lunch")
        #expect(untouched.splits.map(\.value).sorted() == [-25, 25])
        #expect(!f.undo.canUndo)
    }

    @Test("Delete transaction round-trips")
    func deleteTransaction() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()

        f.model.deleteTransaction(id)
        #expect(f.model.book?.transactions.isEmpty == true)

        f.undo.undo()
        #expect(f.model.book?.transaction(with: id)?.transactionDescription == "Lunch")

        f.undo.redo()
        #expect(f.model.book?.transactions.isEmpty == true)
    }

    @Test("Delete via a register row round-trips, splits and all")
    func deleteTransactionForSplit() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()
        let splitID = try #require(f.model.book?.transaction(with: id)?.splits.first?.guid)

        f.model.deleteTransaction(forSplit: splitID)
        #expect(f.model.book?.transactions.isEmpty == true)

        f.undo.undo()
        let restored = try #require(f.model.book?.transaction(with: id))
        #expect(restored.splits.count == 2)
        // The snapshot keeps split guids, so a restored row is the same row.
        #expect(restored.splits.contains { $0.guid == splitID })
        #expect(f.model.book?.split(with: splitID) != nil)
    }

    @Test("Duplicate transaction round-trips")
    func duplicateTransaction() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()

        let copyID = try #require(f.model.duplicateTransaction(id))
        #expect(f.model.book?.transactions.count == 2)

        f.undo.undo()
        #expect(f.model.book?.transactions.count == 1)
        #expect(f.model.book?.transaction(with: copyID) == nil)

        f.undo.redo()
        #expect(f.model.book?.transaction(with: copyID)?.splits.count == 2)
    }

    @Test("Reversing transaction round-trips")
    func addReversingTransaction() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()

        let reversalID = try #require(f.model.addReversingTransaction(id))
        #expect(f.model.book?.transactions.count == 2)

        f.undo.undo()
        #expect(f.model.book?.transactions.count == 1)

        f.undo.redo()
        let reversal = try #require(f.model.book?.transaction(with: reversalID))
        #expect(reversal.splits.map(\.value).sorted() == [-25, 25])
        #expect(reversal.transactionDescription == "Reversal of Lunch")
    }

    @Test("Void transaction round-trips")
    func voidTransaction() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()

        f.model.voidTransaction(id)
        #expect(f.model.book?.transaction(with: id)?.splits.allSatisfy { $0.reconcileState == .voided } == true)

        f.undo.undo()
        #expect(f.model.book?.transaction(with: id)?.splits.allSatisfy { $0.reconcileState == .notReconciled } == true)

        f.undo.redo()
        #expect(f.model.book?.transaction(with: id)?.splits.allSatisfy { $0.reconcileState == .voided } == true)
    }

    @Test("Set reconcile state round-trips")
    func setReconcileState() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()
        let splitID = try #require(f.model.book?.transaction(with: id)?.splits.first?.guid)

        f.model.setReconcileState(splitID: splitID, to: .reconciled)
        #expect(f.model.book?.split(with: splitID)?.reconcileState == .reconciled)

        f.undo.undo()
        #expect(f.model.book?.split(with: splitID)?.reconcileState == .notReconciled)

        f.undo.redo()
        #expect(f.model.book?.split(with: splitID)?.reconcileState == .reconciled)
    }

    @Test("Cycling a reconcile flag round-trips — the register's hottest edit")
    func cycleReconcileState() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()
        let splitID = try #require(f.model.book?.transaction(with: id)?.splits.first?.guid)

        f.model.cycleReconcileState(splitID: splitID)
        #expect(f.model.book?.split(with: splitID)?.reconcileState == .cleared)

        f.undo.undo()
        #expect(f.model.book?.split(with: splitID)?.reconcileState == .notReconciled)

        f.undo.redo()
        #expect(f.model.book?.split(with: splitID)?.reconcileState == .cleared)

        // And again, to prove a snapshot can be replayed more than once.
        f.undo.undo()
        #expect(f.model.book?.split(with: splitID)?.reconcileState == .notReconciled)
    }

    @Test("Only the named transaction is snapshotted — others ride through undo")
    func undoLeavesOtherTransactionsAlone() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let first = try f.seedTransaction("Lunch")
        let second = try f.seedTransaction("Coffee", amount: 5)

        f.model.deleteTransaction(first)
        f.undo.undo()

        #expect(f.model.book?.transactions.count == 2)
        #expect(f.model.book?.transaction(with: first)?.transactionDescription == "Lunch")
        #expect(f.model.book?.transaction(with: second)?.transactionDescription == "Coffee")
    }

    @Test("Add transfer round-trips")
    func addTransfer() throws {
        let f = try Fixture()
        defer { f.tearDown() }

        let id = try #require(f.model.addTransfer(from: f.bank, to: f.food, amount: 25,
                                                  date: Date(), description: "Lunch"))
        f.undo.undo()
        #expect(f.model.book?.transactions.isEmpty == true)

        f.undo.redo()
        #expect(f.model.book?.transaction(with: id)?.splits.count == 2)
    }
}

@MainActor
@Suite("Undo / redo — structural operations")
struct UndoStructuralOperationTests {

    @Test("Edit account round-trips")
    func updateAccount() throws {
        let f = try Fixture()
        defer { f.tearDown() }

        f.model.updateAccount(id: f.bank, name: "Everyday", code: "100", description: "Main",
                              notes: "", isPlaceholder: false, isHidden: false)
        #expect(f.model.book?.account(with: f.bank)?.name == "Everyday")

        f.undo.undo()
        #expect(f.model.book?.account(with: f.bank)?.name == "Bank")

        f.undo.redo()
        #expect(f.model.book?.account(with: f.bank)?.code == "100")
    }

    @Test("Move account round-trips")
    func moveAccount() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let parent = try #require(f.model.addAccount(name: "Assets", type: .asset))
        f.undo.removeAllActions()

        #expect(f.model.moveAccount(f.bank, under: parent))
        #expect(f.model.parentID(ofAccount: f.bank) == parent)

        f.undo.undo()
        #expect(f.model.parentID(ofAccount: f.bank) == nil)

        f.undo.redo()
        #expect(f.model.parentID(ofAccount: f.bank) == parent)
    }

    @Test("Rename account round-trips")
    func renameAccount() throws {
        let f = try Fixture()
        defer { f.tearDown() }

        f.model.renameAccount(f.bank, to: "Everyday")
        #expect(f.model.book?.account(with: f.bank)?.name == "Everyday")

        f.undo.undo()
        #expect(f.model.book?.account(with: f.bank)?.name == "Bank")

        f.undo.redo()
        #expect(f.model.book?.account(with: f.bank)?.name == "Everyday")
    }

    @Test("Add and delete price round-trip")
    func prices() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let acme = Commodity(namespace: .security("ASX"), mnemonic: "ACME",
                             fullName: "Acme Ltd", smallestFraction: 10000)

        f.model.addPrice(commodity: acme, currency: .aud, date: Date(), value: 12)
        #expect(f.model.book?.prices.count == 1)

        f.undo.undo()
        #expect(f.model.book?.prices.isEmpty == true)

        f.undo.redo()
        #expect(f.model.book?.prices.count == 1)
    }

    @Test("Tax flag round-trips (account-scoped undo)")
    func setAccountTax() throws {
        let f = try Fixture()
        defer { f.tearDown() }

        f.model.setAccountTax(id: f.food, related: true, code: "N286")
        #expect(f.model.book?.account(with: f.food)?.taxRelated == true)
        #expect(f.model.book?.account(with: f.food)?.taxCode == "N286")

        f.undo.undo()
        #expect(f.model.book?.account(with: f.food)?.taxRelated == false)
        #expect(f.model.book?.account(with: f.food)?.taxCode == nil)

        f.undo.redo()
        #expect(f.model.book?.account(with: f.food)?.taxCode == "N286")
    }

    @Test("Cascade properties round-trip across the subtree in one undo")
    func cascade() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        // food ▸ dining ▸ takeaway. Hide the parent and cascade it down.
        let dining = try #require(f.model.addAccount(name: "Dining", type: .expense, parentID: f.food))
        let takeaway = try #require(f.model.addAccount(name: "Takeaway", type: .expense, parentID: dining))
        f.model.updateAccount(id: f.food, name: "Food", code: "", description: "", notes: "",
                              isPlaceholder: false, isHidden: true)
        f.undo.removeAllActions()

        let changed = f.model.cascadeProperties(from: f.food, .init(isHidden: true))
        #expect(changed == 2)
        #expect(f.model.book?.account(with: dining)?.isHidden == true)
        #expect(f.model.book?.account(with: takeaway)?.isHidden == true)

        f.undo.undo()
        #expect(f.model.book?.account(with: dining)?.isHidden == false)
        #expect(f.model.book?.account(with: takeaway)?.isHidden == false)

        f.undo.redo()
        #expect(f.model.book?.account(with: takeaway)?.isHidden == true)
    }

    @Test("Undoing a move restores the account's exact sibling position")
    func moveRestoresPosition() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        // Three siblings at the root: bank, food (from the fixture), then a, b.
        // Put `food` between two new accounts so its index is not the edge.
        let a = try #require(f.model.addAccount(name: "A", type: .asset))
        let b = try #require(f.model.addAccount(name: "B", type: .asset))
        let parent = try #require(f.model.addAccount(name: "Parent", type: .asset))
        f.undo.removeAllActions()

        func siblingIndex(_ id: GncGUID) -> Int? {
            f.model.book?.rootAccount.children.firstIndex { $0.guid == id }
        }
        let originalIndex = try #require(siblingIndex(f.food))

        #expect(f.model.moveAccount(f.food, under: parent))
        #expect(siblingIndex(f.food) == nil)                 // no longer a root child

        f.undo.undo()
        #expect(f.model.parentID(ofAccount: f.food) == nil)  // back at the root
        #expect(siblingIndex(f.food) == originalIndex)        // …in its former slot
        _ = (a, b)
    }

    @Test("A transaction undo still works after a whole-book undo")
    func mixedUndoStack() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()

        // A whole-book undo swaps in a fresh object graph; the older
        // transaction snapshot must re-resolve its accounts against it.
        f.model.renameAccount(f.bank, to: "Everyday")
        f.undo.undo()
        #expect(f.model.book?.account(with: f.bank)?.name == "Bank")

        f.model.deleteTransaction(id)
        f.undo.undo()

        let restored = try #require(f.model.book?.transaction(with: id))
        #expect(restored.splits.count == 2)
        #expect(restored.splits.allSatisfy { $0.account != nil })
        // Re-resolved against the live book, not the graph that was replaced.
        let live = try #require(f.model.book?.account(with: f.bank))
        #expect(restored.splits.contains { $0.account === live })
    }
}

@MainActor
@Suite("Undo / redo — action names and grouping")
struct UndoActionNameTests {

    @Test("Edit-menu action names describe the operation")
    func actionNames() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let id = try f.seedTransaction()
        let splitID = try #require(f.model.book?.transaction(with: id)?.splits.first?.guid)

        f.model.cycleReconcileState(splitID: splitID)
        #expect(f.undo.undoActionName == "Change Reconcile State")

        f.undo.undo()
        #expect(f.undo.redoActionName == "Change Reconcile State")
    }

    @Test("Check & Repair coalesces into one undo action")
    func checkRepairIsOneAction() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let book = try #require(f.model.book)

        // Three separate defects, so a per-transaction undo would stack up.
        for _ in 0..<3 {
            book.addTransaction(Transaction(currency: .aud, datePosted: Date(), description: "Empty"))
        }
        f.model.refreshAfterChange()
        f.undo.removeAllActions()

        f.model.applyCleanup()
        #expect(book.transactions.isEmpty)
        #expect(f.undo.undoActionName == "Check & Repair")

        // One undo brings all three back.
        f.undo.undo()
        #expect(f.model.book?.transactions.count == 3)
        #expect(!f.undo.canUndo)
    }
}
