//
//  CheckRepairTests.swift
//  FinvestLens — FeatureUI
//
//  Check & Repair flow (proposal → clean-up) and GnuCash account colours.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Check & Repair")
struct CheckRepairTests {

    @Test("Check & Repair proposes, cleans, and reports")
    func proposeAndClean() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let book = try #require(model.book)
        let bankAccount = try #require(book.account(with: bank))

        // An empty stub and an unbalanced transaction with an orphan split.
        let stub = Transaction(currency: .aud, datePosted: Date(), description: "Opening Balance")
        stub.addSplit(account: bankAccount, value: 0)
        book.addTransaction(stub)
        let broken = Transaction(currency: .aud, datePosted: Date(), description: "Broken")
        broken.addSplit(account: bankAccount, value: 100)
        broken.addSplit(Split(account: nil, value: -60))
        book.addTransaction(broken)

        model.checkAndRepair()
        let proposal = try #require(model.pendingCleanup)
        #expect(proposal.emptyCount == 1)
        #expect(proposal.orphanCount == 1)
        #expect(proposal.unbalancedCount == 1)

        model.applyCleanup()
        #expect(model.pendingCleanup == nil)
        #expect(model.infoMessage?.contains("Clean-up complete") == true)
        #expect(Scrub.check(book).isEmpty)
        #expect(book.transactions.count == 1)                    // stub removed

        // Second run reports a clean bill instead of proposing.
        model.checkAndRepair()
        #expect(model.pendingCleanup == nil)
        #expect(model.infoMessage?.contains("clean") == true)
    }

    @Test("GnuCash import with issues offers cleanup instead of the plain alert")
    func importOffersCleanup() throws {
        let root = GncGUID.random().hexString
        let bank = GncGUID.random().hexString
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <gnc-v2>
        <gnc:book version="2.0.0">
        <gnc:account version="2.0.0">
          <act:name>Root Account</act:name><act:id type="guid">\(root)</act:id><act:type>ROOT</act:type>
        </gnc:account>
        <gnc:account version="2.0.0">
          <act:name>Bank</act:name><act:id type="guid">\(bank)</act:id><act:type>BANK</act:type>
          <act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity>
          <act:parent type="guid">\(root)</act:parent>
        </gnc:account>
        <gnc:transaction version="2.0.0">
          <trn:id type="guid">\(GncGUID.random().hexString)</trn:id>
          <trn:currency><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></trn:currency>
          <trn:date-posted><ts:date>2026-06-01 00:00:00 +0000</ts:date></trn:date-posted>
          <trn:description>Opening Balance</trn:description>
          <trn:splits>
            <trn:split>
              <split:id type="guid">\(GncGUID.random().hexString)</split:id>
              <split:reconciled-state>n</split:reconciled-state>
              <split:value>0/100</split:value><split:quantity>0/100</split:quantity>
              <split:account type="guid">\(bank)</split:account>
            </trn:split>
          </trn:splits>
        </gnc:transaction>
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
        defer { model.close() }
        model.importGnuCashBook(from: source, saveAs: destination)

        #expect(model.infoMessage == nil)                       // no plain alert
        let proposal = try #require(model.pendingCleanup)
        #expect(proposal.emptyCount == 1)
        #expect(proposal.importNote?.contains("Imported 1 accounts") == true)

        model.applyCleanup()
        #expect(model.book?.transactions.isEmpty == true)       // exported file is cleaner
    }
}

@MainActor
@Suite("Account colours")
struct AccountColorTests {

    @Test("GnuCash colour strings parse in all their forms")
    func parsing() {
        #expect(GnuCashColor.color(from: "rgb(144,144,238)") != nil)
        #expect(GnuCashColor.color(from: "#8fbc8f") != nil)
        #expect(GnuCashColor.color(from: "#fff") != nil)
        #expect(GnuCashColor.color(from: "#8f8fbcbc8f8f") != nil)   // GTK 16-bit
        #expect(GnuCashColor.color(from: "Not Set") == nil)
        #expect(GnuCashColor.color(from: "") == nil)
        #expect(GnuCashColor.color(from: "#12345") == nil)          // bad length
    }

    @Test("Serialised colours re-parse to the same channels")
    func serialisationRoundTrip() {
        let text = GnuCashColor.gnuCashString(from: Color(.sRGB, red: 144.0/255, green: 144.0/255, blue: 238.0/255))
        #expect(text == "rgb(144,144,238)")
        #expect(GnuCashColor.color(from: text) != nil)
    }

    @Test("Setting an account colour lands in the tree, the slot, and the file")
    func colorPersists() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        model.setAccountColor(bank, colorString: "rgb(144,144,238)")
        #expect(model.accountTree.first { $0.id == bank }?.color == "rgb(144,144,238)")
        #expect(model.book?.account(with: bank)?.kvp["color"] == .string("rgb(144,144,238)"))
        try model.save()
        model.close()

        try await model.open(at: url)
        defer { model.close() }
        #expect(model.accountColor(bank) == "rgb(144,144,238)")

        model.setAccountColor(bank, colorString: nil)
        #expect(model.accountColor(bank) == nil)
    }
}
