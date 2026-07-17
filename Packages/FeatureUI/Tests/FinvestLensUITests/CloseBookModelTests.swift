//
//  CloseBookModelTests.swift
//  FinvestLens — FeatureUI
//
//  Period-end close through the model: preview, post, and undo.
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
@Suite("Period-end close (model)")
struct CloseBookModelTests {

    private func book() throws -> (AppModel, URL, income: GncGUID, expense: GncGUID, equity: GncGUID) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        let expense = try #require(model.addAccount(name: "Rent", type: .expense))
        let equity = try #require(model.addAccount(name: "Retained", type: .equity))
        try model.addTransaction(date: Date(timeIntervalSince1970: 86_400), description: "Pay",
            currency: .aud, splits: [SplitInput(accountID: bank, value: dec("1000")),
                                     SplitInput(accountID: income, value: dec("-1000"))])
        try model.addTransaction(date: Date(timeIntervalSince1970: 172_800), description: "Rent",
            currency: .aud, splits: [SplitInput(accountID: expense, value: dec("300")),
                                     SplitInput(accountID: bank, value: dec("-300"))])
        return (model, url, income, expense, equity)
    }

    @Test("Preview reports the accounts and net without mutating")
    func preview() throws {
        let (model, url, _, _, equity) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let before = model.book?.transactions.count
        let p = try #require(model.closingPreview(asOf: Date(timeIntervalSince1970: 10_000_000),
                                                  equityID: equity))
        #expect(p.accounts == 2)
        // Single AUD currency; a $700 profit reads as +700 into equity.
        #expect(p.byCurrency.count == 1)
        #expect(p.byCurrency.first?.currencyCode == "AUD")
        #expect(p.byCurrency.first?.netToEquity == dec("700"))
        #expect(model.book?.transactions.count == before)   // preview changed nothing
    }

    @Test("Close posts closing entries and undo removes them")
    func postAndUndo() throws {
        let (model, url, income, expense, equity) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let undo = UndoManager()
        model.undoManager = undo
        let book = try #require(model.book)
        let before = book.transactions.count

        let closed = model.closeBook(asOf: Date(timeIntervalSince1970: 10_000_000), equityID: equity)
        #expect(closed == 2)
        #expect(book.balance(of: try #require(book.account(with: income))).amount == 0)
        #expect(book.balance(of: try #require(book.account(with: expense))).amount == 0)
        #expect(book.balance(of: try #require(book.account(with: equity))).amount == dec("-700"))

        // One undoable action removes the whole close.
        model.undoManager?.undo()
        let after = model.book?.transactions.count
        #expect(after == before)
        #expect(model.book?.balance(of: try #require(model.book?.account(with: income))).amount == dec("-1000"))
    }
}
