//
//  InlineEditTests.swift
//  FinvestLens — FeatureUI
//
//  In-place register editing (AppModel+InlineEdit): field commits, the
//  counter-leg rebalance, the simple-transfer gate, and bulk edits.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Inline register editing")
struct InlineEditTests {

    /// A book with a plain two-leg transfer, returning the ids the tests poke.
    private func makeTransferBook(_ model: AppModel, at url: URL) throws
        -> (bank: GncGUID, groceries: GncGUID, txn: GncGUID, bankSplit: GncGUID) {
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let txn = try #require(model.addTransfer(from: bank, to: groceries, amount: dec("50"),
                                                 date: Date(timeIntervalSince1970: 1_000_000),
                                                 description: "Woolworths"))
        let book = try #require(model.book)
        let bankAccount = try #require(book.account(with: bank))
        let bankSplit = try #require(book.splits(for: bankAccount).first).guid
        return (bank, groceries, txn, bankSplit)
    }

    @Test("isSimpleTransfer is true only for two-leg same-currency transactions")
    func simpleTransferGate() throws {
        let url = tempURL()
        let model = AppModel()
        let ids = try makeTransferBook(model, at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        #expect(model.isSimpleTransfer(splitID: ids.bankSplit))

        // A three-leg transaction is not simple.
        let bank = ids.bank
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let household = try #require(model.addAccount(name: "Household", type: .expense))
        try model.addTransaction(date: Date(timeIntervalSince1970: 2_000_000), description: "Split shop",
                                 currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-30")),
            SplitInput(accountID: food, value: dec("20")),
            SplitInput(accountID: household, value: dec("10"))])
        let book = try #require(model.book)
        let splitTxn = try #require(book.transactions.first { $0.transactionDescription == "Split shop" })
        let splitLeg = try #require(splitTxn.splits.first).guid
        #expect(!model.isSimpleTransfer(splitID: splitLeg))

        // A security leg (commodity != transaction currency) is not simple either.
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let shares = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
        try model.addTransaction(date: Date(timeIntervalSince1970: 3_000_000), description: "Buy CBA",
                                 currency: .aud, splits: [
            SplitInput(accountID: shares, value: dec("1000"), quantity: dec("10")),
            SplitInput(accountID: bank, value: dec("-1000"))])
        let buy = try #require(book.transactions.first { $0.transactionDescription == "Buy CBA" })
        let buyBankLeg = try #require(buy.splits.first { $0.account?.guid == bank }).guid
        #expect(!model.isSimpleTransfer(splitID: buyBankLeg))

        // Unknown split id.
        #expect(!model.isSimpleTransfer(splitID: .random()))
    }

    @Test("Date, description, notes and memo commit from a register row")
    func fieldEdits() throws {
        let url = tempURL()
        let model = AppModel()
        let ids = try makeTransferBook(model, at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let book = try #require(model.book)
        let txn = try #require(book.transaction(with: ids.txn))

        let newDate = Date(timeIntervalSince1970: 5_000_000)
        model.inlineSetDate(splitID: ids.bankSplit, to: newDate)
        #expect(txn.datePosted == newDate)

        model.inlineSetDescription(splitID: ids.bankSplit, to: "  Woolworths Metro  ")
        #expect(txn.transactionDescription == "Woolworths Metro")

        // An empty description is rejected — a transaction needs one.
        model.inlineSetDescription(splitID: ids.bankSplit, to: "   ")
        #expect(txn.transactionDescription == "Woolworths Metro")

        model.inlineSetNotes(splitID: ids.bankSplit, to: "second line")
        #expect(txn.notes == "second line")
        model.inlineSetNotes(splitID: ids.bankSplit, to: "")
        #expect(txn.notes.isEmpty)

        let bankLeg = try #require(book.split(with: ids.bankSplit))
        model.inlineSetMemo(splitID: ids.bankSplit, to: "  card 1234 ")
        #expect(bankLeg.memo == "card 1234")
        model.inlineSetMemo(splitID: ids.bankSplit, to: "")
        #expect(bankLeg.memo.isEmpty)
    }

    @Test("Setting the amount rebalances the counter leg and rounds to the currency")
    func amountRebalance() throws {
        let url = tempURL()
        let model = AppModel()
        let ids = try makeTransferBook(model, at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let book = try #require(model.book)
        let txn = try #require(book.transaction(with: ids.txn))
        let bankLeg = try #require(book.split(with: ids.bankSplit))
        let counterLeg = try #require(txn.splits.first { $0 !== bankLeg })

        // Bank held -50; make the purchase -82.344 → rounded to cents.
        #expect(model.inlineSetAmount(splitID: ids.bankSplit, to: dec("-82.344")))
        #expect(bankLeg.value == dec("-82.34"))
        #expect(bankLeg.quantity == dec("-82.34"))
        #expect(counterLeg.value == dec("82.34"))
        #expect(counterLeg.quantity == dec("82.34"))
        #expect(txn.isBalanced)

        // Same value again: reports success, changes nothing.
        #expect(model.inlineSetAmount(splitID: ids.bankSplit, to: dec("-82.34")))
        #expect(bankLeg.value == dec("-82.34"))
    }

    @Test("Amount edits are refused on multi-leg and security transactions")
    func amountRefusals() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let household = try #require(model.addAccount(name: "Household", type: .expense))
        try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "Split shop",
                                 currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-30")),
            SplitInput(accountID: food, value: dec("20")),
            SplitInput(accountID: household, value: dec("10"))])
        let book = try #require(model.book)
        let splitTxn = try #require(book.transactions.first)
        let bankLeg = try #require(splitTxn.splits.first { $0.account?.guid == bank })
        #expect(!model.inlineSetAmount(splitID: bankLeg.guid, to: dec("-40")))
        #expect(bankLeg.value == dec("-30"))                       // untouched

        // Two legs, but one in a security commodity: refused.
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let shares = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
        try model.addTransaction(date: Date(timeIntervalSince1970: 1000), description: "Buy",
                                 currency: .aud, splits: [
            SplitInput(accountID: shares, value: dec("1000"), quantity: dec("10")),
            SplitInput(accountID: bank, value: dec("-1000"))])
        let buy = try #require(book.transactions.first { $0.transactionDescription == "Buy" })
        let buyBankLeg = try #require(buy.splits.first { $0.account?.guid == bank })
        #expect(!model.inlineSetAmount(splitID: buyBankLeg.guid, to: dec("-900")))
    }

    @Test("Re-categorising moves the counter leg; the row leg stays put")
    func transferEdit() throws {
        let url = tempURL()
        let model = AppModel()
        let ids = try makeTransferBook(model, at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let book = try #require(model.book)
        let txn = try #require(book.transaction(with: ids.txn))
        let bankLeg = try #require(book.split(with: ids.bankSplit))
        let counterLeg = try #require(txn.splits.first { $0 !== bankLeg })

        let dining = try #require(model.addAccount(name: "Dining", type: .expense))
        #expect(model.inlineSetTransfer(splitID: ids.bankSplit, to: dining))
        #expect(counterLeg.account?.guid == dining)
        #expect(bankLeg.account?.guid == ids.bank)                 // unchanged

        // Already there: no-op, reported as a refusal.
        #expect(!model.inlineSetTransfer(splitID: ids.bankSplit, to: dining))

        // A foreign-commodity destination is refused.
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let shares = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
        #expect(!model.inlineSetTransfer(splitID: ids.bankSplit, to: shares))
        #expect(counterLeg.account?.guid == dining)
    }

    @Test("Moving this leg re-homes it, same-currency destinations only")
    func legAccountEdit() throws {
        let url = tempURL()
        let model = AppModel()
        let ids = try makeTransferBook(model, at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let book = try #require(model.book)
        let bankLeg = try #require(book.split(with: ids.bankSplit))

        let savings = try #require(model.addAccount(name: "Savings", type: .bank))
        #expect(model.inlineSetLegAccount(splitID: ids.bankSplit, to: savings))
        #expect(bankLeg.account?.guid == savings)

        // Same account again: refused (nothing to do).
        #expect(!model.inlineSetLegAccount(splitID: ids.bankSplit, to: savings))

        // A security account is refused; the leg stays where it was.
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let shares = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
        #expect(!model.inlineSetLegAccount(splitID: ids.bankSplit, to: shares))
        #expect(bankLeg.account?.guid == savings)
    }
}

@MainActor
@Suite("Bulk register editing")
struct BulkEditTests {

    @Test("A bulk edit applies transaction and split fields across the selection")
    func bulkFieldsApply() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let subs = try #require(model.addAccount(name: "Subscriptions", type: .expense))
        let dining = try #require(model.addAccount(name: "Dining", type: .expense))
        let household = try #require(model.addAccount(name: "Household", type: .expense))

        let t1 = try #require(model.addTransfer(from: bank, to: groceries, amount: dec("10"),
                                                date: Date(timeIntervalSince1970: 0), description: "One"))
        let t2 = try #require(model.addTransfer(from: bank, to: subs, amount: dec("20"),
                                                date: Date(timeIntervalSince1970: 86_400), description: "Two"))
        // A three-leg transaction: its transfer move must be skipped, not botched.
        let t3 = try model.addTransaction(
            date: Date(timeIntervalSince1970: 172_800), description: "Three",
            currency: .aud, splits: [
                SplitInput(accountID: bank, value: dec("-30")),
                SplitInput(accountID: groceries, value: dec("20")),
                SplitInput(accountID: household, value: dec("10"))])

        let book = try #require(model.book)
        let bankAccount = try #require(book.account(with: bank))
        let bankLegs = book.splits(for: bankAccount)
        #expect(bankLegs.count == 3)
        let selection = Set(bankLegs.map(\.guid))

        var edit = AppModel.BulkTransactionEdit()
        #expect(edit.isEmpty)
        let newDate = Date(timeIntervalSince1970: 999_000)
        edit.date = newDate
        edit.description = "  Bulk Renamed "
        edit.notes = " shared note "
        edit.memo = " statement leg "
        edit.reconcile = .cleared
        edit.transferAccountID = dining
        #expect(!edit.isEmpty)

        let result = model.applyBulkEdit(edit, toSplits: selection)
        #expect(result.edited == 3)
        #expect(result.transferSkipped == 1)                       // the three-leg txn

        for id in [t1, t2, t3] {
            let txn = try #require(book.transaction(with: id))
            #expect(txn.datePosted == newDate)
            #expect(txn.transactionDescription == "Bulk Renamed")
            #expect(txn.notes == "shared note")
        }
        for leg in bankLegs {
            #expect(leg.memo == "statement leg")
            #expect(leg.reconcileState == .cleared)
        }
        // Simple transfers moved their counter legs to Dining; the split
        // transaction kept its structure.
        let txn1 = try #require(book.transaction(with: t1))
        let txn2 = try #require(book.transaction(with: t2))
        #expect(txn1.splits.first { $0.account?.guid != bank }?.account?.guid == dining)
        #expect(txn2.splits.first { $0.account?.guid != bank }?.account?.guid == dining)
        let txn3 = try #require(book.transaction(with: t3))
        #expect(txn3.splits.count == 3)
        #expect(txn3.splits.contains { $0.account?.guid == household })
        #expect(!txn3.splits.contains { $0.account?.guid == dining })
    }

    @Test("Reconciling in bulk stamps the reconcile date; blanks clear only what may be blank")
    func bulkReconcileAndBlanks() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        _ = try #require(model.addTransfer(from: bank, to: groceries, amount: dec("10"),
                                           date: Date(timeIntervalSince1970: 0), description: "Keep Me"))
        let book = try #require(model.book)
        let bankAccount = try #require(book.account(with: bank))
        let leg = try #require(book.splits(for: bankAccount).first)
        let txn = try #require(leg.transaction)
        txn.notes = "old note"
        leg.memo = "old memo"

        var edit = AppModel.BulkTransactionEdit()
        edit.reconcile = .reconciled
        edit.description = "   "     // blank description is ignored
        edit.notes = ""              // blank notes clear
        edit.memo = ""               // blank memo clears
        let result = model.applyBulkEdit(edit, toSplits: [leg.guid])
        #expect(result.edited == 1)
        #expect(result.transferSkipped == 0)
        #expect(leg.reconcileState == .reconciled)
        #expect(leg.reconcileDate != nil)
        #expect(txn.transactionDescription == "Keep Me")
        #expect(txn.notes.isEmpty)
        #expect(leg.memo.isEmpty)
    }

    @Test("An empty edit or empty selection edits nothing")
    func bulkNoOps() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        _ = try #require(model.addTransfer(from: bank, to: groceries, amount: dec("10"),
                                           date: Date(timeIntervalSince1970: 0), description: "One"))
        let book = try #require(model.book)
        let leg = try #require(book.splits(for: book.account(with: bank)!).first)

        // Empty edit.
        let empty = model.applyBulkEdit(AppModel.BulkTransactionEdit(), toSplits: [leg.guid])
        #expect(empty == (0, 0))

        // Empty (and unknown) selection.
        var edit = AppModel.BulkTransactionEdit()
        edit.description = "New"
        #expect(model.applyBulkEdit(edit, toSplits: []) == (0, 0))
        #expect(model.applyBulkEdit(edit, toSplits: [.random()]) == (0, 0))
    }
}
