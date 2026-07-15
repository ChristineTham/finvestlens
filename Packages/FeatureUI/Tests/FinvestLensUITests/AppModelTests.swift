//
//  AppModelTests.swift
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
@Suite("AppModel")
struct AppModelTests {

    @Test("New document starts empty")
    func newDocument() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        #expect(model.isOpen)
        #expect(model.accountTree.isEmpty)
    }

    @Test("Adding accounts builds the tree with balances")
    func addAccounts() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let assets = try #require(model.addAccount(name: "Assets", type: .asset))
        _ = model.addAccount(name: "Bank", type: .bank, parentID: assets)
        _ = model.addAccount(name: "Salary", type: .income)

        #expect(model.accountTree.count == 2)                      // Assets, Salary at top
        let assetsNode = try #require(model.accountTree.first { $0.name == "Assets" })
        #expect(assetsNode.children?.count == 1)                    // Bank under Assets
        #expect(model.hasUnsavedChanges)
    }

    @Test("A transfer posts to the register with a running balance")
    func transferAndRegister() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))

        model.addTransfer(from: salary, to: bank, amount: Decimal(string: "100.00")!,
                          date: Date(timeIntervalSince1970: 1_700_000_000), description: "Pay")

        model.selectedAccountID = bank
        #expect(model.registerRows.count == 1)
        #expect(model.registerRows.first?.amount == Decimal(string: "100.00"))
        #expect(model.registerRows.first?.runningBalance == Decimal(string: "100.00"))
        #expect(model.registerRows.first?.transfer == "Salary")

        let bankNode = try #require(model.accountTree.first { $0.name == "Bank" })
        #expect(bankNode.balance == Decimal(100))
    }

    @Test("Delete is guarded for accounts with postings")
    func deleteGuard() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let spare = try #require(model.addAccount(name: "Spare", type: .expense))

        model.addTransfer(from: salary, to: bank, amount: 100, date: Date(), description: "Pay")

        #expect(!model.canDeleteAccount(bank))     // has postings
        #expect(model.canDeleteAccount(spare))     // empty
        try model.deleteAccount(spare)
        #expect(model.accountTree.first { $0.name == "Spare" } == nil)
    }

    @Test("Save then reopen preserves the model")
    func saveReopen() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        model.addTransfer(from: salary, to: bank, amount: 100, date: Date(), description: "Pay")
        try model.save()
        model.close()

        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close() }
        #expect(reopened.accountTree.count == 2)
        reopened.selectedAccountID = reopened.accountTree.first { $0.name == "Bank" }?.id
        #expect(reopened.registerRows.count == 1)
    }
}
