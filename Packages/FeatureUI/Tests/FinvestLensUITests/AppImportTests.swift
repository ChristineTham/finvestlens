//
//  AppImportTests.swift
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
@Suite("Bank import pipeline")
struct AppImportTests {

    @Test("Parse → match → import posts new rows and skips duplicates")
    func endToEnd() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let subs = try #require(model.addAccount(name: "Subscriptions", type: .expense))

        // History: a Woolworths purchase, so it can be detected as a duplicate.
        model.addTransfer(from: bank, to: groceries, amount: Decimal(string: "52.30")!,
                          date: Date(timeIntervalSince1970: 1_600_000_000), description: "Woolworths")
        // addTransfer(from bank to groceries, amount) → groceries +52.30, bank -52.30.

        let qif = """
        !Type:Bank
        D09/13/2020
        T-52.30
        PWoolworths
        ^
        D09/20/2020
        T-19.99
        PNetflix
        ^
        """
        let staged = model.parseBankFile(Data(qif.utf8), format: .qif)
        #expect(staged.count == 2)

        let results = model.matchStaged(staged, intoAccountID: bank)
        let woolworths = try #require(results.first { $0.staged.payee == "Woolworths" })
        let netflix = try #require(results.first { $0.staged.payee == "Netflix" })
        #expect(woolworths.isDuplicate)                 // matches the history row
        #expect(!netflix.isDuplicate)

        // Assign Netflix → Subscriptions; import (skipping the duplicate).
        let imported = model.importMatched(results, intoAccountID: bank,
                                           assignments: [netflix.staged.id: subs])
        #expect(imported == 1)

        // Bank now reflects history (−52.30) + Netflix (−19.99).
        let bankNode = try #require(model.accountTree.first { $0.name == "Bank" })
        #expect(bankNode.balance == Decimal(string: "-72.29"))
        _ = groceries
    }

    @Test("Format is inferred from the extension")
    func formatDetection() {
        #expect(BankFileFormat.forExtension("CSV") == .csv)
        #expect(BankFileFormat.forExtension("qif") == .qif)
        #expect(BankFileFormat.forExtension("qfx") == .ofx)
        #expect(BankFileFormat.forExtension("pdf") == .pdf)  // via Apple Intelligence (FR-AI-01)
        #expect(BankFileFormat.forExtension("docx") == nil)
    }
}
