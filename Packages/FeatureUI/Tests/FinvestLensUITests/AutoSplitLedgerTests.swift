//
//  AutoSplitLedgerTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's Auto-Split Ledger (FR-REG-03, a Should since P2). RegisterStyle had
//  Basic, Journal and General Ledger; the missing one is the middle setting most
//  people keep on — Basic never shows a multi-split transaction's insides, and
//  Journal shows everyone's at once.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Auto-split ledger")
struct AutoSplitLedgerTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let simple: GncGUID
        let multi: GncGUID
    }

    /// A two-split transaction and a four-split one, so "one line each" and
    /// "opened out" are visibly different.
    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let fuel = try #require(model.addAccount(name: "Fuel", type: .expense))
        let fees = try #require(model.addAccount(name: "Fees", type: .expense))

        let simple = try model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "Lunch", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -10),
                     SplitInput(accountID: food, value: 10)])
        let multi = try model.addTransaction(
            date: Date(timeIntervalSince1970: 86_400), description: "Shop", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -60),
                     SplitInput(accountID: food, value: 30),
                     SplitInput(accountID: fuel, value: 25),
                     SplitInput(accountID: fees, value: 5)])
        return Fixture(model: model, url: url, bank: bank, simple: simple, multi: multi)
    }

    @Test("Auto-Split is a register style of its own")
    func styleExists() {
        #expect(RegisterStyle.allCases.contains(.autoSplit))
        #expect(RegisterStyle.autoSplit.rawValue == "Auto-Split")
    }

    /// With nothing selected it is one line per transaction — Basic's shape.
    @Test("Nothing selected shows one line per transaction")
    func collapsed() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let rows = f.model.autoSplitRows(forAccountID: f.bank, expanding: nil)
        let allHeadings = rows.filter { !$0.isHeading }.isEmpty
        #expect(rows.count == 2)
        #expect(allHeadings)
        #expect(rows.map(\.text) == ["Lunch", "Shop"])
    }

    /// The point of the style: the one you are looking at opens out.
    @Test("The selected transaction opens out into its legs")
    func expanded() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let rows = f.model.autoSplitRows(forAccountID: f.bank, expanding: f.multi)
        // Two headings, plus the four legs of the selected one.
        #expect(rows.count == 6)
        #expect(rows.filter(\.isHeading).count == 2)
        let legs = rows.filter { !$0.isHeading }
        #expect(legs.allSatisfy { $0.transactionID == f.multi })
        #expect(legs.map(\.text).sorted() == ["Bank", "Fees", "Food", "Fuel"])
    }

    /// …and only that one. Expanding everyone is the Journal, which is a
    /// different style.
    @Test("Nobody else opens out")
    func onlyTheSelectedOne() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let rows = f.model.autoSplitRows(forAccountID: f.bank, expanding: f.simple)
        #expect(rows.filter { !$0.isHeading }.allSatisfy { $0.transactionID == f.simple })
        #expect(rows.filter { !$0.isHeading }.count == 2)
        // The journal, by contrast, opens out all six legs at once.
        #expect(f.model.journalRows(forAccountID: f.bank).filter { !$0.isHeading }.count == 6)
    }

    @Test("Headings stay in date order with their legs beneath them")
    func ordering() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let rows = f.model.autoSplitRows(forAccountID: f.bank, expanding: f.multi)
        #expect(rows.first?.text == "Lunch")
        #expect(rows[1].text == "Shop")
        // Everything after the "Shop" heading is one of its legs.
        #expect(rows.dropFirst(2).allSatisfy { !$0.isHeading && $0.transactionID == f.multi })
    }

    /// A leg posted to the register's own account is marked, as in the journal —
    /// the style changes which rows are shown, not what they say.
    @Test("Rows say the same things the journal's do")
    func rowsMatchJournal() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let auto = f.model.autoSplitRows(forAccountID: f.bank, expanding: f.multi)
        let journal = f.model.journalRows(forAccountID: f.bank)
        for row in auto {
            let same = try #require(journal.first { $0.id == row.id })
            #expect(same.text == row.text)
            #expect(same.amount == row.amount)
            #expect(same.isFocusAccount == row.isFocusAccount)
        }
        #expect(auto.contains { $0.text == "Bank" && $0.isFocusAccount })
    }

    @Test("Expanding something not in this register changes nothing")
    func unknownExpansion() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let rows = f.model.autoSplitRows(forAccountID: f.bank, expanding: .random())
        let allHeadings = rows.filter { !$0.isHeading }.isEmpty
        #expect(rows.count == 2)
        #expect(allHeadings)
    }

    @Test("An account with no postings has no rows")
    func emptyAccount() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let unused = try #require(f.model.addAccount(name: "Unused", type: .expense))
        #expect(f.model.autoSplitRows(forAccountID: unused, expanding: nil).isEmpty)
    }
}
