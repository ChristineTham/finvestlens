//
//  ImporterTests.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensInterchange

/// A minimal but complete GnuCash v2 document: AUD, a root + Bank + Salary,
/// and one balanced $100 pay transaction. Matches the gzip fixture in
/// `GzipTests`.
private let minimalXML = """
<?xml version="1.0" encoding="utf-8"?>
<gnc-v2 xmlns:gnc="http://www.gnucash.org/XML/gnc" xmlns:act="http://www.gnucash.org/XML/act" xmlns:trn="http://www.gnucash.org/XML/trn" xmlns:split="http://www.gnucash.org/XML/split" xmlns:cmdty="http://www.gnucash.org/XML/cmdty" xmlns:ts="http://www.gnucash.org/XML/ts" xmlns:book="http://www.gnucash.org/XML/book">
<gnc:book version="2.0.0">
<book:id type="guid">a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6</book:id>
<gnc:commodity version="2.0.0"><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id><cmdty:fraction>100</cmdty:fraction><cmdty:name>Australian Dollar</cmdty:name></gnc:commodity>
<gnc:account version="2.0.0"><act:name>Root Account</act:name><act:id type="guid">00000000000000000000000000000000</act:id><act:type>ROOT</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity></gnc:account>
<gnc:account version="2.0.0"><act:name>Bank</act:name><act:id type="guid">11111111111111111111111111111111</act:id><act:type>BANK</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity><act:commodity-scu>100</act:commodity-scu><act:parent type="guid">00000000000000000000000000000000</act:parent></gnc:account>
<gnc:account version="2.0.0"><act:name>Salary</act:name><act:id type="guid">22222222222222222222222222222222</act:id><act:type>INCOME</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity><act:parent type="guid">00000000000000000000000000000000</act:parent></gnc:account>
<gnc:transaction version="2.0.0"><trn:id type="guid">33333333333333333333333333333333</trn:id><trn:currency><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></trn:currency><trn:date-posted><ts:date>2026-01-15 00:00:00 +0000</ts:date></trn:date-posted><trn:description>Pay</trn:description><trn:splits><trn:split><split:id type="guid">44444444444444444444444444444444</split:id><split:reconciled-state>n</split:reconciled-state><split:value>10000/100</split:value><split:quantity>10000/100</split:quantity><split:account type="guid">11111111111111111111111111111111</split:account></trn:split><trn:split><split:id type="guid">55555555555555555555555555555555</split:id><split:reconciled-state>n</split:reconciled-state><split:value>-10000/100</split:value><split:quantity>-10000/100</split:quantity><split:account type="guid">22222222222222222222222222222222</split:account></trn:split></trn:splits></gnc:transaction>
</gnc:book>
</gnc-v2>
"""

private func account(_ result: ImportResult, named name: String) -> Account? {
    result.book.accounts.first { $0.name == name }
}

@Suite("GnuCash XML import")
struct ImporterTests {

    @Test("Imports the account tree, transaction and balances")
    func minimalImport() throws {
        let result = try GnuCashXMLImporter.importBook(from: Data(minimalXML.utf8))

        #expect(result.summary.accountCount == 2)         // Bank + Salary (root excluded)
        #expect(result.summary.transactionCount == 1)
        #expect(result.summary.splitCount == 2)
        #expect(result.summary.commodityCount == 1)

        let bank = try #require(account(result, named: "Bank"))
        let salary = try #require(account(result, named: "Salary"))
        #expect(result.book.balance(of: bank).amount == Decimal(string: "100.00"))
        #expect(result.book.balance(of: salary).amount == Decimal(string: "-100.00"))
    }

    @Test("Preserves GUIDs byte-for-byte")
    func guidPreservation() throws {
        let result = try GnuCashXMLImporter.importBook(from: Data(minimalXML.utf8))
        let bank = try #require(account(result, named: "Bank"))
        #expect(bank.guid.hexString == "11111111111111111111111111111111")
        #expect(result.book.transactions.first?.guid.hexString == "33333333333333333333333333333333")
    }

    @Test("Imported book is Scrub-clean")
    func scrubClean() throws {
        let result = try GnuCashXMLImporter.importBook(from: Data(minimalXML.utf8))
        #expect(result.summary.isClean)
        #expect(result.book.transactions.allSatisfy { $0.isBalanced })
    }

    @Test("Resolves the imported currency")
    func currency() throws {
        let result = try GnuCashXMLImporter.importBook(from: Data(minimalXML.utf8))
        let aud = try #require(result.book.commodities.first { $0.mnemonic == "AUD" })
        #expect(aud.namespace == .currency)
        #expect(aud.smallestFraction == 100)
    }

    @Test("Gzip and plain imports agree")
    func gzipMatchesPlain() throws {
        let gz = try #require(Data(base64Encoded: GzipTests.minimalGzipBase64))
        let fromGzip = try GnuCashXMLImporter.importBook(from: gz)
        let fromPlain = try GnuCashXMLImporter.importBook(from: Data(minimalXML.utf8))

        #expect(fromGzip.summary.accountCount == fromPlain.summary.accountCount)
        #expect(fromGzip.summary.transactionCount == fromPlain.summary.transactionCount)
        #expect(fromGzip.book.transactions.first?.guid == fromPlain.book.transactions.first?.guid)
    }

    @Test("Reads placeholder and hidden slots")
    func slots() throws {
        let xml = """
        <?xml version="1.0"?>
        <gnc-v2 xmlns:gnc="g" xmlns:act="a" xmlns:cmdty="c" xmlns:slot="s">
        <gnc:book version="2.0.0">
        <gnc:commodity version="2.0.0"><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id><cmdty:fraction>100</cmdty:fraction></gnc:commodity>
        <gnc:account version="2.0.0"><act:name>Root</act:name><act:id type="guid">00000000000000000000000000000000</act:id><act:type>ROOT</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity></gnc:account>
        <gnc:account version="2.0.0"><act:name>Assets</act:name><act:id type="guid">aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</act:id><act:type>ASSET</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity><act:parent type="guid">00000000000000000000000000000000</act:parent><act:slots><slot><slot:key>placeholder</slot:key><slot:value type="string">true</slot:value></slot><slot><slot:key>hidden</slot:key><slot:value type="string">true</slot:value></slot></act:slots></gnc:account>
        </gnc:book>
        </gnc-v2>
        """
        let result = try GnuCashXMLImporter.importBook(from: Data(xml.utf8))
        let assets = try #require(account(result, named: "Assets"))
        #expect(assets.isPlaceholder)
        #expect(assets.isHidden)
    }

    @Test("Detects an unbalanced transaction via Scrub")
    func unbalancedDetected() throws {
        let xml = """
        <?xml version="1.0"?>
        <gnc-v2 xmlns:gnc="g" xmlns:act="a" xmlns:trn="t" xmlns:split="sp" xmlns:cmdty="c" xmlns:ts="ts">
        <gnc:book version="2.0.0">
        <gnc:commodity version="2.0.0"><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id><cmdty:fraction>100</cmdty:fraction></gnc:commodity>
        <gnc:account version="2.0.0"><act:name>Root</act:name><act:id type="guid">00000000000000000000000000000000</act:id><act:type>ROOT</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity></gnc:account>
        <gnc:account version="2.0.0"><act:name>Bank</act:name><act:id type="guid">11111111111111111111111111111111</act:id><act:type>BANK</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity><act:parent type="guid">00000000000000000000000000000000</act:parent></gnc:account>
        <gnc:account version="2.0.0"><act:name>Wage</act:name><act:id type="guid">22222222222222222222222222222222</act:id><act:type>INCOME</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity><act:parent type="guid">00000000000000000000000000000000</act:parent></gnc:account>
        <gnc:transaction version="2.0.0"><trn:id type="guid">33333333333333333333333333333333</trn:id><trn:currency><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></trn:currency><trn:date-posted><ts:date>2026-01-15 00:00:00 +0000</ts:date></trn:date-posted><trn:splits><trn:split><split:id type="guid">44444444444444444444444444444444</split:id><split:reconciled-state>n</split:reconciled-state><split:value>10000/100</split:value><split:quantity>10000/100</split:quantity><split:account type="guid">11111111111111111111111111111111</split:account></trn:split><trn:split><split:id type="guid">55555555555555555555555555555555</split:id><split:reconciled-state>n</split:reconciled-state><split:value>-9000/100</split:value><split:quantity>-9000/100</split:quantity><split:account type="guid">22222222222222222222222222222222</split:account></trn:split></trn:splits></gnc:transaction>
        </gnc:book>
        </gnc-v2>
        """
        let result = try GnuCashXMLImporter.importBook(from: Data(xml.utf8))
        #expect(!result.summary.isClean)
        #expect(result.summary.scrubIssues.contains {
            if case .unbalancedTransaction = $0 { return true } else { return false }
        })
    }

    @Test("Empty data throws")
    func emptyData() {
        #expect(throws: ImportError.emptyData) {
            try GnuCashXMLImporter.importBook(from: Data())
        }
    }
}
