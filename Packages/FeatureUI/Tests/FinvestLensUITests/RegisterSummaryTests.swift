//
//  RegisterSummaryTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's register status strip (View ▸ Summary Bar): Present / Future /
//  Cleared / Reconciled, computed from the engine's existing `BalanceFilter`
//  so the strip agrees with the sidebar and reports to the cent.
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
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}
private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@MainActor
@Suite("Register summary bar")
struct RegisterSummaryTests {

    @Test("Present / cleared / reconciled match the engine's filtered balances")
    func matchesEngine() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Income", type: .income))
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        let future = Date(timeIntervalSince1970: 4_000_000_000)   // year 2096

        // A reconciled deposit, a cleared one, an uncleared one, and a
        // future-dated one — one of each reconcile lens.
        model.addTransfer(from: income, to: bank, amount: dec("100"), date: past, description: "Recon")
        model.addTransfer(from: income, to: bank, amount: dec("50"), date: past, description: "Clear")
        model.addTransfer(from: income, to: bank, amount: dec("20"), date: past, description: "Uncleared")
        model.addTransfer(from: income, to: bank, amount: dec("500"), date: future, description: "Future")

        model.selectedAccountID = bank
        // Reconcile-state helpers act on the selected account's splits.
        let rows = model.registerRows
        try model.setReconcileState(splitID: #require(rows.first { $0.description == "Recon" }).id, to: .reconciled)
        try model.setReconcileState(splitID: #require(rows.first { $0.description == "Clear" }).id, to: .cleared)

        let s = try #require(model.registerSummary)

        // Future includes everything; present excludes the year-2096 row.
        #expect(s.future == dec("670"))
        #expect(s.present == dec("170"))
        #expect(s.hasFuture)
        // Cleared = cleared + reconciled (100 + 50); reconciled = 100.
        #expect(s.cleared == dec("150"))
        #expect(s.reconciled == dec("100"))
        #expect(s.currencyCode == "AUD")
        #expect(!s.isSecurity)

        // The strip is exactly the engine's own filtered balances.
        let book = try #require(model.book)
        let acct = try #require(book.account(with: bank))
        #expect(s.cleared == book.balance(of: acct, filter: .cleared).rounded.amount)
        #expect(s.reconciled == book.balance(of: acct, filter: .reconciled).rounded.amount)
        #expect(s.future == book.balance(of: acct, filter: .all).rounded.amount)
    }

    @Test("No summary without a selection, or across mixed commodities")
    func gating() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        #expect(model.registerSummary == nil)          // nothing selected

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        model.selectedAccountID = bank
        #expect(model.registerSummary != nil)           // a plain currency leaf is fine
        #expect(model.registerSummary?.present == 0)     // empty, but present
    }
}
