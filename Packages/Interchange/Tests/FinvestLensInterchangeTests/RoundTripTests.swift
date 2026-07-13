//
//  RoundTripTests.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensInterchange

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private let day = Date(timeIntervalSince1970: 1_700_000_000)

/// Builds a book with a placeholder parent, two postable accounts, and one
/// balanced transaction — exercising hierarchy, slots, GUIDs, and amounts.
private func makeBook() -> Book {
    let book = Book(baseCurrency: .aud)
    let assets = book.addAccount(Account(name: "Assets", type: .asset, commodity: .aud, isPlaceholder: true))
    let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud, code: "1001"), under: assets)
    let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
    let txn = Transaction(currency: .aud, datePosted: day, description: "Pay & Co <test>")
    txn.addSplit(account: bank, value: dec("100.00"))
    txn.addSplit(account: salary, value: dec("-100.00"))
    book.addTransaction(txn)
    return book
}

private func account(_ result: ImportResult, _ name: String) -> Account? {
    result.book.accounts.first { $0.name == name }
}

@Suite("GnuCash XML round-trip")
struct RoundTripTests {

    @Test("Structure, GUIDs, slots and balances survive export → import")
    func roundTrip() throws {
        let original = makeBook()
        let bankGUID = try #require(original.accounts.first { $0.name == "Bank" }).guid
        let txnGUID = try #require(original.transactions.first).guid

        let data = GnuCashXMLExporter.export(original)
        let result = try GnuCashXMLImporter.importBook(from: data)

        #expect(result.summary.accountCount == 3)
        #expect(result.summary.transactionCount == 1)
        #expect(result.summary.isClean)

        let bank = try #require(account(result, "Bank"))
        let salary = try #require(account(result, "Salary"))
        let assets = try #require(account(result, "Assets"))

        #expect(bank.guid == bankGUID)                              // GUID preserved
        #expect(result.book.transactions.first?.guid == txnGUID)
        #expect(bank.fullName == "Assets:Bank")                     // hierarchy preserved
        #expect(bank.code == "1001")
        #expect(assets.isPlaceholder)                              // slot preserved
        #expect(result.book.balance(of: bank).rounded.amount == dec("100.00"))
        #expect(result.book.balance(of: salary).rounded.amount == dec("-100.00"))
    }

    @Test("Amounts round-trip exactly (within Decimal tolerance)")
    func amounts() throws {
        let original = makeBook()
        let data = GnuCashXMLExporter.export(original)
        let result = try GnuCashXMLImporter.importBook(from: data)
        let bank = try #require(account(result, "Bank"))
        #expect(result.book.balance(of: bank).rounded.amount == dec("100.00"))
        // Every re-imported transaction still balances.
        #expect(result.book.transactions.allSatisfy { $0.isBalanced })
    }

    @Test("Gzip export is valid and re-imports identically")
    func gzipRoundTrip() throws {
        let original = makeBook()
        let gz = GnuCashXMLExporter.export(original, compressed: true)
        #expect(Gzip.isGzipped(gz))

        let result = try GnuCashXMLImporter.importBook(from: gz)   // importer auto-detects gzip
        #expect(result.summary.accountCount == 3)
        let bank = try #require(account(result, "Bank"))
        #expect(result.book.balance(of: bank).rounded.amount == dec("100.00"))
    }

    @Test("Special characters are XML-escaped and restored")
    func escaping() throws {
        let original = makeBook()
        let data = GnuCashXMLExporter.export(original)
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.contains("Pay &amp; Co &lt;test&gt;"))         // escaped on the wire

        let result = try GnuCashXMLImporter.importBook(from: data)
        #expect(result.book.transactions.first?.transactionDescription == "Pay & Co <test>")
    }

    @Test("Exported XML declares the book and account GUIDs")
    func exportedContents() {
        let original = makeBook()
        let xml = String(decoding: GnuCashXMLExporter.export(original), as: UTF8.self)
        #expect(xml.contains("<gnc-v2"))
        #expect(xml.contains(original.guid.hexString))
        #expect(xml.contains("cd:type=\"account\">4"))            // root + 3 accounts
    }

    @Test("Double round-trip is stable")
    func doubleRoundTrip() throws {
        let original = makeBook()
        let once = try GnuCashXMLImporter.importBook(from: GnuCashXMLExporter.export(original))
        let twice = try GnuCashXMLImporter.importBook(from: GnuCashXMLExporter.export(once.book))
        #expect(twice.summary.accountCount == once.summary.accountCount)
        #expect(twice.book.transactions.first?.guid == once.book.transactions.first?.guid)
        let bank = try #require(account(twice, "Bank"))
        #expect(twice.book.balance(of: bank).rounded.amount == dec("100.00"))
    }
}

@Suite("Document link round-trip")
struct DocumentLinkRoundTripTests {

    @Test("assoc_uri survives export → import (GnuCash association)")
    func documentLink() throws {
        let original = makeBook()
        original.transactions.first?.documentLink = "invoices/officeworks-559023.pdf"

        let data = GnuCashXMLExporter.export(original)
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.contains("<slot:key>assoc_uri</slot:key>"))
        #expect(xml.contains("invoices/officeworks-559023.pdf"))

        let result = try GnuCashXMLImporter.importBook(from: data)
        #expect(result.summary.isClean)
        #expect(result.book.transactions.first?.documentLink == "invoices/officeworks-559023.pdf")
    }

    @Test("Notes on accounts and transactions round-trip into their properties")
    func notesRoundTrip() throws {
        let book = makeBook()
        book.accounts.first { $0.name == "Bank" }!.notes = "Joint account\nwith Alex"
        book.transactions.first!.notes = "Reimbursed by work"
        let result = try GnuCashXMLImporter.importBook(from: GnuCashXMLExporter.export(book))
        #expect(account(result, "Bank")?.notes == "Joint account\nwith Alex")
        #expect(result.book.transactions.first?.notes == "Reimbursed by work")
        // Lifted into the property, not duplicated in the frame.
        #expect(account(result, "Bank")?.kvp["notes"] == nil)
    }

    @Test("Unknown slots round-trip verbatim on every level")
    func slotPreservation() throws {
        let book = makeBook()
        book.kvp["features"] = .frame(KvpFrame(["Budgets": .string("Budgets")]))
        let bank = book.accounts.first { $0.name == "Bank" }!
        bank.kvp["color"] = .string("rgb(144,144,238)")
        bank.kvp["reconcile-info"] = .frame(KvpFrame([
            "include-children": .int64(0),
            "last-date": .date(Date(timeIntervalSince1970: 1_700_006_400)),  // midnight UTC
        ]))
        let txn = book.transactions.first!
        txn.kvp["date-posted"] = .date(Date(timeIntervalSince1970: 1_699_920_000))
        txn.kvp["gains-source"] = .guid(GncGUID.random())
        let split = txn.splits[0]
        split.kvp["online_id"] = .string("0161 130257 1234")
        split.kvp["weight"] = .numeric(dec("0.25"))

        let result = try GnuCashXMLImporter.importBook(from: GnuCashXMLExporter.export(book))
        #expect(result.book.kvp == book.kvp)
        let bank2 = try #require(account(result, "Bank"))
        #expect(bank2.kvp == bank.kvp)
        let txn2 = try #require(result.book.transactions.first)
        #expect(txn2.kvp == txn.kvp)
        #expect(txn2.splits.first { $0.guid == split.guid }?.kvp == split.kvp)
    }

    @Test("Tags (a KVP list) survive the XML round-trip")
    func tagsRoundTrip() throws {
        let book = makeBook()
        book.transactions.first!.tags = ["holiday", "reimbursable"]
        let result = try GnuCashXMLImporter.importBook(from: GnuCashXMLExporter.export(book))
        #expect(result.book.transactions.first?.tags == ["holiday", "reimbursable"])
    }

    @Test("Commodity quote config, xcode, and slots survive export → import")
    func commodityFidelity() throws {
        let book = makeBook()
        var stock = Commodity(namespace: .security("ASX"), mnemonic: "PPT.AX",
                              fullName: "Perpetual Limited", smallestFraction: 10000)
        stock.exchangeCode = "PPT.AX"
        stock.getQuotes = true
        stock.quoteSource = "yahoo_json"
        stock.quoteTimezone = ""            // present-but-empty, GnuCash's usual form
        stock.kvp["user_symbol"] = .string("PPT")
        book.registerCommodity(stock)

        let result = try GnuCashXMLImporter.importBook(from: GnuCashXMLExporter.export(book))
        let imported = try #require(result.book.commodities.first { $0.mnemonic == "PPT.AX" })
        #expect(imported.fullName == "Perpetual Limited")
        #expect(imported.exchangeCode == "PPT.AX")
        #expect(imported.getQuotes)
        #expect(imported.quoteSource == "yahoo_json")
        #expect(imported.quoteTimezone == "")
        #expect(imported.kvp["user_symbol"] == .string("PPT"))
        // A plain currency stays plain: no quote elements invented.
        let aud = try #require(result.book.commodities.first { $0.mnemonic == "AUD" })
        #expect(!aud.getQuotes && aud.quoteSource == nil
                && aud.quoteTimezone == nil && aud.exchangeCode == nil)
    }

    @Test("Book GUID survives export → import")
    func bookGUID() throws {
        let book = makeBook()
        let result = try GnuCashXMLImporter.importBook(from: GnuCashXMLExporter.export(book))
        #expect(result.book.guid == book.guid)
    }

    @Test("Sub-cent price values survive (not rounded to the currency fraction)")
    func pricePrecision() throws {
        let book = makeBook()
        let stock = Commodity(namespace: .security("ASX"), mnemonic: "BHP",
                              fullName: "BHP Group", smallestFraction: 10000)
        book.registerCommodity(stock)
        book.addPrice(Price(commodity: stock, currency: .aud, date: day,
                            value: dec("12.3456"), source: "user:price"))
        let result = try GnuCashXMLImporter.importBook(from: GnuCashXMLExporter.export(book))
        #expect(result.book.prices.first?.value == dec("12.3456"))
    }

    @Test("A non-terminating rational price (FX cross-rate) survives exactly")
    func oddRationalPrice() throws {
        let book = makeBook()
        let value = Decimal(71211) / Decimal(46999)   // repeating decimal
        book.addPrice(Price(commodity: .aud, currency: .aud, date: day, value: value))
        let once = try GnuCashXMLImporter.importBook(from: GnuCashXMLExporter.export(book))
        #expect(once.book.prices.first?.value == value)
        // And the double export is byte-stable.
        let twice = GnuCashXMLExporter.export(once.book)
        #expect(twice == GnuCashXMLExporter.export(
            try GnuCashXMLImporter.importBook(from: twice).book))
    }

    @Test("gnc:template-transactions never hijack the book root or the ledger")
    func templateTransactionsSkipped() throws {
        let realRoot = GncGUID.random().hexString
        let bank = GncGUID.random().hexString
        let templateRoot = GncGUID.random().hexString
        let templateAcct = GncGUID.random().hexString
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <gnc-v2>
        <gnc:book version="2.0.0">
        <gnc:account version="2.0.0">
          <act:name>Root Account</act:name>
          <act:id type="guid">\(realRoot)</act:id>
          <act:type>ROOT</act:type>
        </gnc:account>
        <gnc:account version="2.0.0">
          <act:name>Bank</act:name>
          <act:id type="guid">\(bank)</act:id>
          <act:type>BANK</act:type>
          <act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity>
          <act:parent type="guid">\(realRoot)</act:parent>
        </gnc:account>
        <gnc:template-transactions>
        <gnc:account version="2.0.0">
          <act:name>Template Root</act:name>
          <act:id type="guid">\(templateRoot)</act:id>
          <act:type>ROOT</act:type>
        </gnc:account>
        <gnc:account version="2.0.0">
          <act:name>SX Template</act:name>
          <act:id type="guid">\(templateAcct)</act:id>
          <act:type>BANK</act:type>
          <act:parent type="guid">\(templateRoot)</act:parent>
        </gnc:account>
        <gnc:transaction version="2.0.0">
          <trn:id type="guid">\(GncGUID.random().hexString)</trn:id>
          <trn:description>Template posting</trn:description>
        </gnc:transaction>
        </gnc:template-transactions>
        </gnc:book>
        </gnc-v2>
        """
        let result = try GnuCashXMLImporter.importBook(from: Data(xml.utf8))
        #expect(result.book.rootAccount.guid.hexString == realRoot)
        #expect(result.book.accounts.count == 1)
        #expect(result.book.accounts.first?.name == "Bank")
        #expect(result.book.transactions.isEmpty)
        #expect(result.summary.warnings.contains { $0.contains("template") })
    }

    @Test("Transactions without a link export no trn:slots")
    func noLink() {
        let xml = String(decoding: GnuCashXMLExporter.export(makeBook()), as: UTF8.self)
        #expect(!xml.contains("<trn:slots>"))
    }
}
