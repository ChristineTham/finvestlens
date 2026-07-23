//
//  ForeignRestructureTests.swift
//  FinvestLens — FeatureUI tests
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Foreign restructure (FR-CUR-01)")
struct ForeignRestructureTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-\(UUID().uuidString).finvestlens")
    }

    /// The Royal Chulan case: an AUD 600 card charge whose invoice reads
    /// RM 1,773.84 becomes a MYR-denominated transaction — values ±1,773.84
    /// balance it, quantities ±600 keep moving the accounts — with the implied
    /// rate recorded in the price DB.
    @Test("AUD charge restructures to MYR values with AUD quantities")
    func restructure() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let visa = try #require(model.addAccount(name: "ANZ VISA", type: .credit))
        let hotel = try #require(model.addAccount(name: "Accommodation", type: .expense))
        let txnID = try #require(model.addTransfer(
            from: hotel, to: visa, amount: -600,
            date: Date(timeIntervalSince1970: 1_770_000_000),
            description: "ROYAL CHULAN KUALA LUMPUR"))

        #expect(model.restructureAsForeign(transactionID: txnID,
                                           foreignAmount: Decimal(string: "1773.84")!,
                                           currencyCode: "MYR"))

        let book = try #require(model.book)
        let txn = try #require(book.transaction(with: txnID))
        #expect(txn.currency.mnemonic == "MYR")
        #expect(txn.isBalanced)   // values sum to zero in MYR

        let visaLeg = try #require(txn.splits.first { $0.account?.name == "ANZ VISA" })
        let hotelLeg = try #require(txn.splits.first { $0.account?.name == "Accommodation" })
        #expect(visaLeg.value == Decimal(string: "-1773.84"))
        #expect(visaLeg.quantity == -600)   // the account still moves by AUD 600
        #expect(hotelLeg.value == Decimal(string: "1773.84"))
        #expect(hotelLeg.quantity == 600)

        // The implied rate landed in the price DB (1 MYR ≈ 0.3383 AUD).
        let rate = try #require(model.storedFxRate(code: "MYR", on: txn.datePosted))
        #expect(abs(rate - Decimal(600) / Decimal(string: "1773.84")!) < Decimal(string: "0.0001")!)

        // And the register still shows the AUD figure.
        model.selectedAccountID = visa
        let row = try #require(model.registerRows.first)
        #expect(row.amount == -600)
    }

    @Test("Multi-leg and same-currency transactions are refused")
    func refusals() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let visa = try #require(model.addAccount(name: "Card", type: .credit))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let txnID = try #require(model.addTransfer(
            from: food, to: visa, amount: -50, date: .now, description: "Lunch"))

        // Same code as the transaction currency: nothing to restructure.
        let base = model.reportCurrency.mnemonic
        #expect(!model.restructureAsForeign(transactionID: txnID,
                                            foreignAmount: 120, currencyCode: base))
        // Same amount: no mismatch, no restructure.
        #expect(!model.restructureAsForeign(transactionID: txnID,
                                            foreignAmount: 50, currencyCode: "MYR"))
        // Near-parity difference (a surcharge, not a currency): refused. The
        // Trip A Deal case — an 87.98 invoice against an ~89.65 charge.
        #expect(!model.restructureAsForeign(transactionID: txnID,
                                            foreignAmount: Decimal(string: "49.10")!,
                                            currencyCode: "USD"))
        let txn = try #require(model.book?.transaction(with: txnID))
        #expect(txn.currency.mnemonic == base)
    }
}
