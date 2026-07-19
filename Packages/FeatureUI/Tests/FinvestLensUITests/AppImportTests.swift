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

    @Test("A QIF split record imports as a multi-category transaction (FR-XIO-01)")
    func splitImport() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        _ = try #require(model.addAccount(name: "Groceries", type: .expense))
        _ = try #require(model.addAccount(name: "Household", type: .expense))

        let qif = """
        !Type:Bank
        D01/15/2024
        T-120.00
        PSupermarket
        SGroceries
        $-90.00
        SHousehold
        $-30.00
        ^
        """
        let staged = model.parseBankFile(Data(qif.utf8), format: .qif)
        #expect(staged.first?.isSplit == true)

        let results = model.matchStaged(staged, intoAccountID: bank)
        #expect(model.importMatched(results, intoAccountID: bank) == 1)

        // Bank −120; each category leg posted to its account.
        let bankNode = try #require(model.accountTree.first { $0.name == "Bank" })
        #expect(bankNode.balance == Decimal(string: "-120.00"))
        let groceriesNode = try #require(model.accountTree.first { $0.name == "Groceries" })
        #expect(groceriesNode.balance == Decimal(string: "90.00"))
        let householdNode = try #require(model.accountTree.first { $0.name == "Household" })
        #expect(householdNode.balance == Decimal(string: "30.00"))
    }

    @Test("GnuCash import preserves prices, book GUID, and KVP into the saved document")
    func gnuCashImportKeepsEverything() async throws {
        let bookGUID = GncGUID.random().hexString
        let root = GncGUID.random().hexString
        let bank = GncGUID.random().hexString
        let priceGUID = GncGUID.random().hexString
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <gnc-v2>
        <gnc:book version="2.0.0">
        <book:id type="guid">\(bookGUID)</book:id>
        <book:slots><slot><slot:key>feature-x</slot:key>
          <slot:value type="string">on</slot:value></slot></book:slots>
        <gnc:commodity version="2.0.0">
          <cmdty:space>ASX</cmdty:space><cmdty:id>BHP</cmdty:id>
          <cmdty:name>BHP Group</cmdty:name><cmdty:fraction>10000</cmdty:fraction>
        </gnc:commodity>
        <gnc:pricedb version="1">
          <price>
            <price:id type="guid">\(priceGUID)</price:id>
            <price:commodity><cmdty:space>ASX</cmdty:space><cmdty:id>BHP</cmdty:id></price:commodity>
            <price:currency><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></price:currency>
            <price:time><ts:date>2026-06-01 00:00:00 +0000</ts:date></price:time>
            <price:value>4512/100</price:value>
          </price>
        </gnc:pricedb>
        <gnc:account version="2.0.0">
          <act:name>Root Account</act:name><act:id type="guid">\(root)</act:id><act:type>ROOT</act:type>
        </gnc:account>
        <gnc:account version="2.0.0">
          <act:name>Bank</act:name><act:id type="guid">\(bank)</act:id><act:type>BANK</act:type>
          <act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity>
          <act:parent type="guid">\(root)</act:parent>
        </gnc:account>
        </gnc:book>
        </gnc-v2>
        """
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).gnucash")
        let destination = tempURL()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data(xml.utf8).write(to: source)

        let model = AppModel()
        model.importGnuCashBook(from: source, saveAs: destination)
        #expect(model.documentError == nil)
        try #require(model.isOpen)

        // In memory: the price, book GUID, and book KVP came across.
        #expect(model.book?.prices.count == 1)
        #expect(model.book?.guid.hexString == bookGUID)
        #expect(model.book?.kvp["feature-x"] == .string("on"))
        try model.save()
        model.close()

        // On disk (after reopen): all of it persisted.
        try await model.open(at: destination)
        defer { model.close() }
        #expect(model.book?.prices.count == 1)
        #expect(model.book?.prices.first?.value == Decimal(string: "45.12"))
        #expect(model.book?.guid.hexString == bookGUID)
        #expect(model.book?.kvp["feature-x"] == .string("on"))
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
