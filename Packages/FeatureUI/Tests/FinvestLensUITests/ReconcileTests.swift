//
//  ReconcileTests.swift
//  FinvestLens — FeatureUI
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

@MainActor
@Suite("Reconciliation")
struct ReconcileTests {

    /// Bank + Salary + Groceries, with two deposits and one withdrawal.
    private func setup() throws -> (AppModel, bank: GncGUID, URL) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))

        model.addTransfer(from: salary, to: bank, amount: 1000,
                          date: Date(timeIntervalSince1970: 1_600_000_000), description: "Pay 1")
        model.addTransfer(from: salary, to: bank, amount: 500,
                          date: Date(timeIntervalSince1970: 1_610_000_000), description: "Pay 2")
        model.addTransfer(from: bank, to: groceries, amount: 200,
                          date: Date(timeIntervalSince1970: 1_620_000_000), description: "Shop")
        return (model, bank, url)
    }

    @Test("Begin builds items and difference from the statement")
    func begin() throws {
        let (model, bank, url) = try setup()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        // Statement covers all three: net balance = 1000 + 500 − 200 = 1300.
        model.beginReconcile(accountID: bank, statementDate: Date(),
                             statementBalance: Decimal(1300))
        let session = try #require(model.reconcileSession)
        #expect(session.items.count == 3)
        #expect(session.startingBalance == 0)
        #expect(session.difference == Decimal(1300))       // nothing cleared yet
        #expect(!session.isBalanced)
    }

    @Test("Clearing items reconciles to zero and persists state")
    func clearToZero() throws {
        let (model, bank, url) = try setup()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.beginReconcile(accountID: bank, statementDate: Date(),
                             statementBalance: Decimal(1300))
        for item in try #require(model.reconcileSession).items {
            model.toggleReconcileItem(item.id)
        }
        let session = try #require(model.reconcileSession)
        #expect(session.clearedBalance == Decimal(1300))
        #expect(session.difference == 0)
        #expect(session.isBalanced)

        #expect(model.finishReconcile())
        #expect(model.reconcileSession == nil)

        // All three splits are now reconciled → reconciled register balance = 1300.
        model.selectedAccountID = bank
        #expect(model.registerRows.allSatisfy { $0.reconcile == "y" })
    }

    @Test("Finish is refused while unbalanced")
    func refusesUnbalanced() throws {
        let (model, bank, url) = try setup()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.beginReconcile(accountID: bank, statementDate: Date(),
                             statementBalance: Decimal(1300))
        // Clear only the first item → difference ≠ 0.
        let first = try #require(model.reconcileSession?.items.first)
        model.toggleReconcileItem(first.id)
        #expect(!(model.reconcileSession?.isBalanced ?? true))
        #expect(!model.finishReconcile())
        #expect(model.reconcileSession != nil)             // session stays open
    }

    @Test("A second reconciliation starts from the reconciled balance")
    func startingBalanceCarries() throws {
        let (model, bank, url) = try setup()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        // First: reconcile the two deposits only (balance 1500).
        model.beginReconcile(accountID: bank, statementDate: Date(timeIntervalSince1970: 1_615_000_000),
                             statementBalance: Decimal(1500))
        for item in try #require(model.reconcileSession).items { model.toggleReconcileItem(item.id) }
        #expect(model.finishReconcile())

        // Second: only the withdrawal remains unreconciled; starting balance = 1500.
        model.beginReconcile(accountID: bank, statementDate: Date(),
                             statementBalance: Decimal(1300))
        let session = try #require(model.reconcileSession)
        #expect(session.startingBalance == Decimal(1500))
        #expect(session.items.count == 1)
        #expect(session.difference == Decimal(-200))       // 1300 − 1500, before clearing the −200 item
    }
}
