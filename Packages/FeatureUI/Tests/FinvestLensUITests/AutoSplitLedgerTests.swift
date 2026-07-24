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

    /// RD1's Show All Splits: every transaction opened out at once — the
    /// journal read in the same table. Legs on screen as main rows are not
    /// repeated, and each transaction expands exactly once.
    @Test("Show All Splits opens every transaction out")
    func expandAll() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.bank
        let rows = f.model.autoSplitRows(expanding: nil, expandAll: true)
        // Two main rows + one counter-leg (Lunch) + three counter-legs (Shop).
        #expect(rows.count == 6)
        #expect(rows.filter { $0.main != nil }.count == 2)
        #expect(rows.filter { $0.main == nil }.count == 4)
        // Order: each transaction's legs directly follow its row.
        #expect(rows[0].main?.description == "Lunch")
        #expect(rows[1].main == nil)
        #expect(rows[2].main?.description == "Shop")
        #expect(rows[3].main == nil)
    }

    /// With nothing selected it is one line per transaction — Basic's shape.
    @Test("Nothing selected shows one line per transaction")
    func collapsed() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.bank
        let rows = f.model.autoSplitRows(expanding: nil)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.main != nil })
        #expect(rows.compactMap(\.main?.description) == ["Lunch", "Shop"])
    }

    /// The point of the style: the one you are looking at opens out. Legs that
    /// are already on screen as main rows (the bank leg) are not repeated.
    @Test("The selected transaction opens out into its legs")
    func expanded() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.bank
        let rows = f.model.autoSplitRows(expanding: f.multi)
        // Two transaction rows, plus the three counter-legs of the multi.
        #expect(rows.count == 5)
        #expect(rows.filter { $0.main != nil }.count == 2)
        let legs = rows.filter { $0.main == nil }
        #expect(legs.map(\.legAccount).sorted() == ["Fees", "Food", "Fuel"])
    }

    /// …and only that one. Expanding everyone is the Journal, which is a
    /// different style.
    @Test("Nobody else opens out")
    func onlyTheSelectedOne() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.bank
        let rows = f.model.autoSplitRows(expanding: f.simple)
        // The simple transaction's one counter-leg (Food); Shop stays closed.
        #expect(rows.filter { $0.main == nil }.map(\.legAccount) == ["Food"])
        // The journal, by contrast, opens out all six legs at once.
        #expect(f.model.journalRows(forAccountID: f.bank).filter { !$0.isHeading }.count == 6)
    }

    @Test("Rows stay in date order with the expanded legs beneath their row")
    func ordering() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.bank
        let rows = f.model.autoSplitRows(expanding: f.multi)
        #expect(rows.first?.main?.description == "Lunch")
        #expect(rows[1].main?.description == "Shop")
        // Everything after the "Shop" row is one of its legs.
        #expect(rows.dropFirst(2).allSatisfy { $0.main == nil })
    }

    /// Auto-Split IS the Basic register: its main rows are the register's rows,
    /// amounts and running balances included.
    @Test("Main rows are the Basic register's rows")
    func rowsMatchRegister() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.bank
        let auto = f.model.autoSplitRows(expanding: f.multi)
        let register = f.model.registerRows
        for row in auto where row.main != nil {
            let same = try #require(register.first { $0.id == row.id })
            #expect(same.description == row.main?.description)
            #expect(same.amount == row.main?.amount)
        }
    }

    @Test("Expanding something not in this register changes nothing")
    func unknownExpansion() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = f.bank
        let rows = f.model.autoSplitRows(expanding: .random())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.main != nil })
    }

    @Test("An account with no postings has no rows")
    func emptyAccount() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let unused = try #require(f.model.addAccount(name: "Unused", type: .expense))
        f.model.selectedAccountID = unused
        #expect(f.model.autoSplitRows(expanding: nil).isEmpty)
    }
}
