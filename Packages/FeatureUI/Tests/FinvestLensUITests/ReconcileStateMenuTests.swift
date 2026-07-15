//
//  ReconcileStateMenuTests.swift
//  FinvestLens — FeatureUI
//
//  Reaching every reconcile state from the register.
//
//  `setReconcileState` has handled all five states since it was written and had
//  no caller outside its own tests: the R column cycles n → c → y, Void/Unvoid
//  covers v, and frozen was unreachable — importable, storable, exportable and
//  displayable, but impossible to set.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Reconcile state menu")
struct ReconcileStateMenuTests {

    private func makeModel() throws -> (AppModel, URL, split: GncGUID, txn: GncGUID) {
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
        let book = try #require(model.book)
        let split = try #require(book.transaction(with: txn)?.splits.first?.guid)
        return (model, url, split, txn)
    }

    /// The state that had no way in.
    @Test("Frozen can be set from the register")
    func frozenIsReachable() throws {
        let (model, url, split, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.setReconcileState(splitID: split, to: .frozen)
        #expect(model.reconcileState(ofSplit: split) == .frozen)
    }

    /// Frozen is outside the cycle, so the R column must leave it alone — the
    /// menu is the only way in and the only way out.
    @Test("Clicking the R column does not disturb a frozen split")
    func cycleLeavesFrozenAlone() throws {
        let (model, url, split, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.setReconcileState(splitID: split, to: .frozen)
        model.cycleReconcileState(splitID: split)
        #expect(model.reconcileState(ofSplit: split) == .frozen)
        // …and the menu can still get it out again.
        model.setReconcileState(splitID: split, to: .notReconciled)
        #expect(model.reconcileState(ofSplit: split) == .notReconciled)
    }

    @Test("Every state the menu offers can actually be set")
    func allOfferedStatesRoundTrip() throws {
        let (model, url, split, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        for state in ReconcileState.settableInRegister {
            model.setReconcileState(splitID: split, to: state)
            #expect(model.reconcileState(ofSplit: split) == state)
        }
    }

    /// Voiding is an operation, not a flag: it rewrites the transaction and is
    /// undone by Unvoid. A picker that could assign `v` is the shape of the bug
    /// where a stray click un-voided a transaction one split at a time.
    @Test("The menu does not offer Voided")
    func voidedIsNotOffered() {
        #expect(!ReconcileState.settableInRegister.contains(.voided))
        #expect(ReconcileState.settableInRegister
                == [.notReconciled, .cleared, .reconciled, .frozen])
    }

    @Test("Every state has a name to show")
    func labels() {
        #expect(ReconcileState.notReconciled.label == "Not Reconciled")
        #expect(ReconcileState.frozen.label == "Frozen")
        #expect(ReconcileState.voided.label == "Voided")
        // No state may fall back to its raw letter.
        #expect(ReconcileState.allCases.allSatisfy { $0.label.count > 1 })
    }

    @Test("Reading the state of an unknown split gives nothing")
    func unknownSplit() throws {
        let (model, url, _, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        #expect(model.reconcileState(ofSplit: .random()) == nil)
    }

    /// Setting a state is an edit like any other.
    @Test("Setting frozen is undoable")
    func undoable() throws {
        let (model, url, split, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let undo = UndoManager()
        model.undoManager = undo
        model.setReconcileState(splitID: split, to: .cleared)
        undo.removeAllActions()

        model.setReconcileState(splitID: split, to: .frozen)
        #expect(model.reconcileState(ofSplit: split) == .frozen)
        undo.undo()
        #expect(model.reconcileState(ofSplit: split) == .cleared)
    }
}
