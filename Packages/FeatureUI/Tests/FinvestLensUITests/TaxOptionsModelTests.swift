//
//  TaxOptionsModelTests.swift
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
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}
private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }

@MainActor
@Suite("Tax options (model)")
struct TaxOptionsModelTests {

    @Test("Flagging an account is undoable and shows in the schedule")
    func flagAndSchedule() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        try model.addTransaction(date: day(10), description: "Pay", currency: .aud,
            splits: [SplitInput(accountID: bank, value: dec("1000")),
                     SplitInput(accountID: salary, value: dec("-1000"))])

        // Attach the UndoManager after setup, so only the tax edit is on the
        // stack (as the other whole-book-undo tests do).
        let undo = UndoManager(); model.undoManager = undo
        let from = day(0), to = day(360)

        #expect(model.book?.account(with: salary)?.taxRelated == false)
        #expect(model.taxAccounts(from: from, to: to).filter(\.taxRelated).isEmpty)

        model.setAccountTax(id: salary, related: true, code: "N286")

        #expect(model.book?.account(with: salary)?.taxRelated == true)
        #expect(model.book?.account(with: salary)?.taxCode == "N286")

        let schedule = model.taxAccounts(from: from, to: to).filter(\.taxRelated)
        #expect(schedule.count == 1)
        #expect(schedule.first?.taxCode == "N286")
        #expect(schedule.first?.periodBalance == dec("1000"))   // income reads positive

        // One undo clears the flag; a whole-book undo swaps the book, so re-read.
        undo.undo()
        #expect(model.book?.account(with: salary)?.taxRelated == false)
        #expect(model.taxAccounts(from: from, to: to).filter(\.taxRelated).isEmpty)
    }

    @Test("The account list covers income and expense, not asset accounts")
    func listMembership() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        _ = try #require(model.addAccount(name: "Bank", type: .bank))
        _ = try #require(model.addAccount(name: "Salary", type: .income))
        _ = try #require(model.addAccount(name: "Rent", type: .expense))

        let names = Set(model.taxAccounts(from: day(0), to: day(360)).map(\.name))
        #expect(names == ["Salary", "Rent"])
    }
}
