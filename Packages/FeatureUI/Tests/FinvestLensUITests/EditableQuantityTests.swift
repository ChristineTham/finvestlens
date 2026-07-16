//
//  EditableQuantityTests.swift
//  FinvestLens — FeatureUI
//
//  The quantity field (GnuCash's Edit Exchange Rate). It was carried blind —
//  the one number you could not fix on an FX or security leg — and making it
//  editable revives the original hazard in a new form: text that does not
//  parse must not quietly become "same as the value".
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Editable quantity")
struct EditableQuantityTests {

    @Test("An empty quantity still means: follow the value")
    func emptyFollowsValue() {
        var line = EditableSplit(accountID: .random(), amountText: "100")
        line.quantityText = ""
        #expect(line.quantity == nil)
        #expect(line.quantityIsValid)
        #expect(line.asInput.quantity == nil)
    }

    @Test("An edited quantity comes back out as edited")
    func editedQuantityRoundTrips() {
        var line = EditableSplit(accountID: .random(), amountText: "400")
        line.quantityText = "11600"
        #expect(line.asInput.quantity == 11_600)
        #expect(line.quantityIsValid)
    }

    /// "1o" is a typo, not an instruction to set the share count to the dollar
    /// value — the sheet must refuse to save rather than guess.
    @Test("A quantity that does not parse is invalid, not nil")
    func garbageIsInvalid() {
        var line = EditableSplit(accountID: .random(), amountText: "400")
        line.quantityText = "1o"
        #expect(!line.quantityIsValid)
    }

    @Test("A loaded split shows the quantity it carried")
    func loadedQuantityIsShown() {
        let input = SplitInput(accountID: .random(), value: 400, quantity: 10)
        let line = EditableSplit(input)
        #expect(line.quantityText == "10")
        #expect(line.asInput.quantity == 10)
    }

    /// Whole edit path: change a share count through updateTransaction and the
    /// book holds the new count, at the same dollar value.
    @Test("Editing a share count changes shares, not dollars")
    func shareCountEdit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let book = try #require(model.book)
        let bhpCommodity = Commodity(namespace: .security("ASX"), mnemonic: "BHP",
                                     fullName: "BHP", smallestFraction: 10000)
        let bhp = book.addAccount(Account(name: "BHP", type: .stock, commodity: bhpCommodity))

        let txn = try model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "Buy", currency: .aud,
            splits: [SplitInput(accountID: bhp.guid, value: 400, quantity: 10),
                     SplitInput(accountID: bank, value: -400)])

        var splits = try #require(model.editData(forTransaction: txn)).splits
        let index = try #require(splits.firstIndex { $0.accountID == bhp.guid })
        splits[index].quantity = 12                       // the corrected count
        _ = try model.updateTransaction(id: txn, date: Date(timeIntervalSince1970: 0),
                                        description: "Buy", currency: .aud, splits: splits)

        let leg = try #require(book.transaction(with: txn)?.splits
            .first { $0.account === bhp })
        #expect(leg.quantity == 12)
        #expect(leg.value == 400)
    }
}
