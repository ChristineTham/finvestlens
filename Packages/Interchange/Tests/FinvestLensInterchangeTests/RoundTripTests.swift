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

    @Test("Transactions without a link export no trn:slots")
    func noLink() {
        let xml = String(decoding: GnuCashXMLExporter.export(makeBook()), as: UTF8.self)
        #expect(!xml.contains("<trn:slots>"))
    }
}
