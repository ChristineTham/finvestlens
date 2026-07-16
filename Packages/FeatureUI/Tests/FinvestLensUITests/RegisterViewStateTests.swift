//
//  RegisterViewStateTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's Save Sort Order / Save Filter, without the button: leaving a
//  register remembers how it was arranged, returning restores it. Held in
//  UserDefaults rather than the book, as GnuCash holds the same facts in its
//  state file — how you looked at an account is not part of what the account
//  is, and sorting a register must not dirty the document.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite(.serialized)
struct RegisterViewStateTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let cash: GncGUID
    }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let cash = try #require(model.addAccount(name: "Cash", type: .cash))
        return Fixture(model: model, url: url, bank: bank, cash: cash)
    }

    private func cleanDefaults(_ f: Fixture) {
        for id in [f.bank, f.cash] {
            UserDefaults.standard.removeObject(forKey: "registerView.\(id.hexString)")
        }
    }

    @Test("Leaving a register and coming back restores its arrangement")
    func roundTripsAcrossAccountSwitch() throws {
        let f = try makeFixture()
        defer { cleanDefaults(f); f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.selectedAccountID = f.bank
        f.model.registerSort = .amount
        f.model.registerSortReversed = true
        f.model.registerFilter = RegisterFilter(statuses: [.reconciled])

        f.model.selectedAccountID = f.cash
        // The new register starts from the default, not the old one's settings.
        #expect(f.model.registerSort == .standard)
        #expect(!f.model.registerSortReversed)
        #expect(f.model.registerFilter.isShowingEverything)

        f.model.selectedAccountID = f.bank
        #expect(f.model.registerSort == .amount)
        #expect(f.model.registerSortReversed)
        #expect(f.model.registerFilter.statuses == [.reconciled])
    }

    /// Each account remembers its own arrangement — that is the whole point of
    /// "per account".
    @Test("Two accounts keep two arrangements")
    func perAccount() throws {
        let f = try makeFixture()
        defer { cleanDefaults(f); f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.selectedAccountID = f.bank
        f.model.registerSort = .amount
        f.model.selectedAccountID = f.cash
        f.model.registerSort = .description

        f.model.selectedAccountID = f.bank
        #expect(f.model.registerSort == .amount)
        f.model.selectedAccountID = f.cash
        #expect(f.model.registerSort == .description)
    }

    /// Resetting a register to the default must *forget* it, not remember the
    /// default — a stored default is indistinguishable until the defaults
    /// change, and then it is wrong.
    @Test("The default arrangement stores nothing")
    func defaultIsForgotten() throws {
        let f = try makeFixture()
        defer { cleanDefaults(f); f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.selectedAccountID = f.bank
        f.model.registerSort = .amount
        f.model.selectedAccountID = f.cash                     // persists bank
        #expect(UserDefaults.standard.data(forKey: "registerView.\(f.bank.hexString)") != nil)

        f.model.selectedAccountID = f.bank
        f.model.registerSort = .standard                       // back to default
        f.model.selectedAccountID = f.cash                     // persists again
        #expect(UserDefaults.standard.data(forKey: "registerView.\(f.bank.hexString)") == nil)
    }

    /// Arranging a register is looking, not editing.
    @Test("Sorting a register does not dirty the book")
    func sortingIsNotAnEdit() throws {
        let f = try makeFixture()
        defer { cleanDefaults(f); f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        try f.model.save()
        #expect(!f.model.hasUnsavedChanges)

        f.model.selectedAccountID = f.bank
        f.model.registerSort = .amount
        f.model.registerSortReversed = true
        f.model.selectedAccountID = f.cash
        #expect(!f.model.hasUnsavedChanges)
    }

    @Test("Closing the book remembers the last register's arrangement")
    func persistsOnClose() throws {
        let f = try makeFixture()
        defer { cleanDefaults(f); try? FileManager.default.removeItem(at: f.url) }

        f.model.selectedAccountID = f.bank
        f.model.registerSort = .memo
        f.model.close()
        #expect(UserDefaults.standard.data(forKey: "registerView.\(f.bank.hexString)") != nil)

        // …and a fresh model restores it on return.
        let again = AppModel()
        defer { again.close() }
        try again.newDocument(at: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens"))
        again.selectedAccountID = f.bank
        #expect(again.registerSort == .memo)
    }
}
