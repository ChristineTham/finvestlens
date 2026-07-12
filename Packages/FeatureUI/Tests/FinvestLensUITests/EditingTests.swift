//
//  EditingTests.swift
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
private func makeModel() throws -> (AppModel, bank: GncGUID, salary: GncGUID, groceries: GncGUID, URL) {
    let url = tempURL()
    let model = AppModel()
    try model.newDocument(at: url)
    let bank = try #require(model.addAccount(name: "Bank", type: .bank))
    let salary = try #require(model.addAccount(name: "Salary", type: .income))
    let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
    return (model, bank, salary, groceries, url)
}

@MainActor
@Suite("Editing")
struct EditingTests {

    @Test("Multi-split transaction must balance")
    func multiSplitBalancing() throws {
        let (model, bank, salary, groceries, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        // Unbalanced → throws.
        #expect(throws: TransactionEntryError.self) {
            try model.addTransaction(date: Date(), description: "Bad", currency: .aud, splits: [
                SplitInput(accountID: bank, value: 100),
                SplitInput(accountID: salary, value: -90),
            ])
        }

        // A three-split paycheck that balances.
        try model.addTransaction(date: Date(), description: "Pay", currency: .aud, splits: [
            SplitInput(accountID: bank, value: Decimal(string: "80")!),
            SplitInput(accountID: groceries, value: Decimal(string: "20")!),
            SplitInput(accountID: salary, value: Decimal(string: "-100")!),
        ])
        model.selectedAccountID = salary
        #expect(model.registerRows.count == 1)
        #expect(model.registerRows.first?.transfer == "— Split —")
    }

    @Test("Delete, duplicate and reverse")
    func lifecycle() throws {
        let (model, bank, salary, _, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let txn = try model.addTransaction(date: Date(), description: "Pay", currency: .aud, splits: [
            SplitInput(accountID: bank, value: 100), SplitInput(accountID: salary, value: -100),
        ])
        model.selectedAccountID = bank
        #expect(model.registerRows.count == 1)

        _ = model.duplicateTransaction(txn)
        #expect(model.registerRows.count == 2)                 // two identical postings

        _ = model.addReversingTransaction(txn)
        #expect(model.registerRows.count == 3)
        // Net balance: 100 + 100 - 100 = 100
        let bankNode = try #require(model.accountTree.first { $0.name == "Bank" })
        #expect(bankNode.balance == Decimal(100))

        model.deleteTransaction(txn)
        #expect(model.registerRows.count == 2)
    }

    @Test("Voiding removes a transaction from balances")
    func voiding() throws {
        let (model, bank, salary, _, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let txn = try model.addTransaction(date: Date(), description: "Pay", currency: .aud, splits: [
            SplitInput(accountID: bank, value: 100), SplitInput(accountID: salary, value: -100),
        ])
        var bankNode = try #require(model.accountTree.first { $0.name == "Bank" })
        #expect(bankNode.balance == Decimal(100))

        model.voidTransaction(txn)
        bankNode = try #require(model.accountTree.first { $0.name == "Bank" })
        #expect(bankNode.balance == Decimal(0))                // voided, excluded
    }

    @Test("Reconcile state cycles n → c → y → n")
    func reconcileCycle() throws {
        let (model, bank, salary, _, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        try model.addTransaction(date: Date(), description: "Pay", currency: .aud, splits: [
            SplitInput(accountID: bank, value: 100), SplitInput(accountID: salary, value: -100),
        ])
        model.selectedAccountID = bank
        let splitID = try #require(model.registerRows.first?.id)

        #expect(model.registerRows.first?.reconcile == "n")
        model.cycleReconcileState(splitID: splitID)
        #expect(model.registerRows.first?.reconcile == "c")
        model.cycleReconcileState(splitID: splitID)
        #expect(model.registerRows.first?.reconcile == "y")
        model.cycleReconcileState(splitID: splitID)
        #expect(model.registerRows.first?.reconcile == "n")
    }

    @Test("Reparenting guards against cycles")
    func reparent() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let assets = try #require(model.addAccount(name: "Assets", type: .asset))
        let bank = try #require(model.addAccount(name: "Bank", type: .bank, parentID: assets))

        #expect(!model.moveAccount(assets, under: bank))       // would create a cycle
        #expect(model.moveAccount(bank, under: nil))           // move to top level
        #expect(model.accountTree.contains { $0.name == "Bank" })
    }

    @Test("Search matches description and account name")
    func search() throws {
        let (model, bank, salary, groceries, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        try model.addTransaction(date: Date(), description: "Woolworths", currency: .aud, splits: [
            SplitInput(accountID: groceries, value: 50), SplitInput(accountID: bank, value: -50),
        ])
        try model.addTransaction(date: Date(), description: "Employer pay", currency: .aud, splits: [
            SplitInput(accountID: bank, value: 100), SplitInput(accountID: salary, value: -100),
        ])

        model.searchQuery = "wool"
        #expect(model.searchResults.count == 1)
        #expect(model.searchResults.first?.description == "Woolworths")

        model.searchQuery = "salary"      // matches by account name
        #expect(model.searchResults.count == 1)
        #expect(model.searchResults.first?.description == "Employer pay")

        model.searchQuery = ""
        #expect(model.searchResults.isEmpty)
    }

    @Test("Editing a transaction in place, with re-validation")
    func editTransaction() throws {
        let (model, bank, salary, groceries, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let txn = try model.addTransaction(date: Date(), description: "Pay", currency: .aud, splits: [
            SplitInput(accountID: bank, value: 100), SplitInput(accountID: salary, value: -100),
        ])

        let edit = try #require(model.editData(forTransaction: txn))
        #expect(edit.description == "Pay")
        #expect(edit.splits.count == 2)

        // Re-route $30 of the pay into groceries; still balances.
        try model.updateTransaction(id: txn, date: edit.date, description: "Pay + shop", currency: .aud, splits: [
            SplitInput(accountID: bank, value: 70),
            SplitInput(accountID: groceries, value: 30),
            SplitInput(accountID: salary, value: -100),
        ])

        model.selectedAccountID = bank
        #expect(model.registerRows.first?.description == "Pay + shop")
        #expect(model.registerRows.first?.amount == Decimal(70))

        // An unbalanced edit is rejected.
        #expect(throws: TransactionEntryError.self) {
            try model.updateTransaction(id: txn, date: edit.date, description: "x", currency: .aud, splits: [
                SplitInput(accountID: bank, value: 70), SplitInput(accountID: salary, value: -100),
            ])
        }
    }

    @Test("Jump selects the counter-account")
    func jump() throws {
        let (model, bank, salary, _, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        try model.addTransaction(date: Date(), description: "Pay", currency: .aud, splits: [
            SplitInput(accountID: bank, value: 100), SplitInput(accountID: salary, value: -100),
        ])
        model.selectedAccountID = bank
        let splitID = try #require(model.registerRows.first?.id)
        model.jumpToOtherAccount(ofSplit: splitID)
        #expect(model.selectedAccountID == salary)
    }

    @Test("Editing an account's fields")
    func editAccount() throws {
        let (model, bank, _, _, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let edit = try #require(model.editData(forAccount: bank))
        #expect(edit.name == "Bank")
        model.updateAccount(id: bank, name: "Everyday", code: "1001", description: "Cheque account",
                            notes: "", isPlaceholder: false, isHidden: true)
        let node = try #require(model.accountTree.first { $0.id == bank })
        #expect(node.name == "Everyday")
        #expect(node.isHidden)
    }

    @Test("QuickFill suggests and templates recent entries")
    func quickFill() throws {
        let (model, bank, _, groceries, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        try model.addTransaction(date: Date(timeIntervalSince1970: 1), description: "Coffee Shop",
                                 currency: .aud, splits: [
            SplitInput(accountID: groceries, value: 5), SplitInput(accountID: bank, value: -5),
        ])

        #expect(model.descriptionSuggestions(prefix: "cof") == ["Coffee Shop"])
        let template = try #require(model.template(forDescription: "Coffee Shop"))
        #expect(template.count == 2)
        #expect(template.contains { $0.accountID == groceries && $0.value == Decimal(5) })
    }
}
