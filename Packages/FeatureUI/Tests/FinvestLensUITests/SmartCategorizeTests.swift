//
//  SmartCategorizeTests.swift
//  FinvestLens — FeatureUI
//
//  The rule-based auto-categoriser (AppModel+SmartCategorize): raw-to-raw
//  matching against the money-leg memo, split-structure scaling, the rename
//  convention, and the guards — ambiguity, weak matches, direction.
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
@Suite("Smart categorise")
struct SmartCategorizeTests {

    /// A book with a bank account, an `Imbalance-AUD` holding account, and a
    /// learned history of three distinct payees (so a payee's own tokens are
    /// distinctive under the per-account IDF).
    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let imbalance: GncGUID
        let salary: GncGUID
        let tax: GncGUID
        let groceries: GncGUID
        let subs: GncGUID
    }

    private func makeFixture() throws -> Fixture {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let imbalance = try #require(model.addAccount(name: "Imbalance-AUD", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let tax = try #require(model.addAccount(name: "Tax Withheld", type: .expense))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let subs = try #require(model.addAccount(name: "Subscriptions", type: .expense))

        // The learned history: each transaction is a rename — the friendly label
        // in the description, the raw bank narrative preserved in the bank-leg
        // memo. The salary is a three-way split (net = gross + withholding).
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_000_000),
                                 description: "Salary", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("3000"), memo: "ACME PTY LTD PAYROLL 00123"),
            SplitInput(accountID: salary, value: dec("-3500")),
            SplitInput(accountID: tax, value: dec("500"))])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_100_000),
                                 description: "Woolworths", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-80"), memo: "WOOLWORTHS 1234 SYDNEY"),
            SplitInput(accountID: groceries, value: dec("80"))])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_200_000),
                                 description: "Netflix", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-20"), memo: "NETFLIX COM SUBSCRIPTION"),
            SplitInput(accountID: subs, value: dec("20"))])
        return Fixture(model: model, url: url, bank: bank, imbalance: imbalance,
                       salary: salary, tax: tax, groceries: groceries, subs: subs)
    }

    @Test("A raw import matches its payee's template and inherits the scaled split structure")
    func planFromTemplate() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        // A raw import: half the usual pay, counter-leg parked in Imbalance.
        let target = try f.model.addTransaction(
            date: Date(timeIntervalSince1970: 2_000_000),
            description: "ACME PTY LTD PAYROLL 00456", currency: .aud, splits: [
                SplitInput(accountID: f.bank, value: dec("1500")),
                SplitInput(accountID: f.imbalance, value: dec("-1500"))])

        let items = f.model.uncategorizedItems()
        #expect(items.count == 1)
        #expect(items.first?.transactionID == target)

        let plans = f.model.smartCategoryPlans(for: items)
        let plan = try #require(plans[target])
        #expect(plan.templateDescription == "Salary")
        #expect(plan.confidence > 0.99)
        // Renamed to the friendly label; the raw narrative moves to the bank leg.
        #expect(plan.newDescription == "Salary")
        #expect(plan.displayDescription == "Salary")
        #expect(plan.transactionDescription == "ACME PTY LTD PAYROLL 00456")
        #expect(plan.currencyCode == "AUD")

        // The template's split structure, scaled from 3000 to 1500 (factor 0.5).
        #expect(plan.legs.count == 2)
        let salaryLeg = try #require(plan.legs.first { $0.accountID == f.salary })
        let taxLeg = try #require(plan.legs.first { $0.accountID == f.tax })
        #expect(salaryLeg.value == dec("-1750"))
        #expect(taxLeg.value == dec("250"))
        // The plan balances against the anchor exactly.
        #expect(plan.legs.reduce(Decimal(0)) { $0 + $1.value } == dec("-1500"))

        // The anchor is the bank leg (never the imbalance leg).
        let book = try #require(f.model.book)
        let bankLeg = try #require(book.splits(for: book.account(with: f.bank)!)
            .first { $0.transaction?.guid == target })
        #expect(plan.anchorSplitIDs == [bankLeg.guid])
    }

    @Test("Applying a plan replaces the imbalance leg, balances, and preserves the narrative")
    func applyPlan() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let target = try f.model.addTransaction(
            date: Date(timeIntervalSince1970: 2_000_000),
            description: "ACME PTY LTD PAYROLL 00456", currency: .aud, splits: [
                SplitInput(accountID: f.bank, value: dec("1500")),
                SplitInput(accountID: f.imbalance, value: dec("-1500"))])
        let plans = f.model.smartCategoryPlans(for: f.model.uncategorizedItems())
        let plan = try #require(plans[target])

        // Aim an assignment at the same transaction's imbalance leg too: the
        // plan wins and the assignment is skipped, never double-applied.
        let book = try #require(f.model.book)
        let imbalanceLeg = try #require(book.splits(for: book.account(with: f.imbalance)!).first)
        let applied = f.model.applyCategorization(plans: [plan],
                                                  assignments: [imbalanceLeg.guid: f.groceries])
        #expect(applied == 1)

        let txn = try #require(book.transaction(with: target))
        #expect(txn.transactionDescription == "Salary")
        #expect(txn.isBalanced)
        #expect(txn.splits.count == 3)
        #expect(!txn.splits.contains { $0.account?.isImbalanceOrOrphan ?? false })
        let bankLeg = try #require(txn.splits.first { $0.account?.guid == f.bank })
        #expect(bankLeg.memo == "ACME PTY LTD PAYROLL 00456")     // narrative preserved
        #expect(bankLeg.value == dec("1500"))
        #expect(txn.splits.first { $0.account?.guid == f.salary }?.value == dec("-1750"))
        #expect(txn.splits.first { $0.account?.guid == f.tax }?.value == dec("250"))
        // Nothing went to the assignment's account, and nothing is left to do.
        #expect(book.splits(for: book.account(with: f.groceries)!)
            .allSatisfy { $0.transaction?.guid != target })
        #expect(f.model.uncategorizedItems().isEmpty)
    }

    @Test("Two payees matching equally well is ambiguous: no plan")
    func ambiguityGuard() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let imbalance = try #require(model.addAccount(name: "Imbalance-AUD", type: .bank))
        let miscA = try #require(model.addAccount(name: "Camera Gear", type: .expense))
        let miscB = try #require(model.addAccount(name: "Games", type: .expense))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))

        // Two payees whose narratives differ only in their distinctive token,
        // plus an unrelated third entry so those tokens clear the IDF bar.
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_000_000),
                                 description: "Alpha Payment", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-100"), memo: "ONLINE TRANSFER ALPHA HOLDINGS"),
            SplitInput(accountID: miscA, value: dec("100"))])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_100_000),
                                 description: "Beta Payment", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-100"), memo: "ONLINE TRANSFER BETA HOLDINGS"),
            SplitInput(accountID: miscB, value: dec("100"))])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_200_000),
                                 description: "Woolworths", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-80"), memo: "WOOLWORTHS SYDNEY"),
            SplitInput(accountID: groceries, value: dec("80"))])

        // The new debit reads like both payees at once.
        _ = try model.addTransaction(
            date: Date(timeIntervalSince1970: 2_000_000),
            description: "ONLINE TRANSFER ALPHA BETA HOLDINGS", currency: .aud, splits: [
                SplitInput(accountID: bank, value: dec("-50")),
                SplitInput(accountID: imbalance, value: dec("50"))])

        let plans = model.smartCategoryPlans(for: model.uncategorizedItems())
        #expect(plans.isEmpty)                                     // abstains, never guesses
    }

    @Test("A weak overlap with a rich narrative stays below the score threshold: no plan")
    func belowThreshold() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let imbalance = try #require(model.addAccount(name: "Imbalance-AUD", type: .bank))
        let misc = try #require(model.addAccount(name: "Misc", type: .expense))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let subs = try #require(model.addAccount(name: "Subscriptions", type: .expense))

        try model.addTransaction(date: Date(timeIntervalSince1970: 1_000_000),
                                 description: "Complex Payee", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-100"), memo: "ALPHA BRAVO CHARLIE DELTA ECHO"),
            SplitInput(accountID: misc, value: dec("100"))])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_100_000),
                                 description: "Woolworths", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-80"), memo: "WOOLWORTHS SYDNEY"),
            SplitInput(accountID: groceries, value: dec("80"))])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_200_000),
                                 description: "Netflix", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-20"), memo: "NETFLIX COM SUBSCRIPTION"),
            SplitInput(accountID: subs, value: dec("20"))])

        // Shares two of the template's five distinctive tokens: 0.4 < 0.6.
        _ = try model.addTransaction(
            date: Date(timeIntervalSince1970: 2_000_000),
            description: "ALPHA BRAVO UNRELATED WORDS HERE", currency: .aud, splits: [
                SplitInput(accountID: bank, value: dec("-50")),
                SplitInput(accountID: imbalance, value: dec("50"))])

        #expect(model.smartCategoryPlans(for: model.uncategorizedItems()).isEmpty)
    }

    @Test("A deposit-shaped template never categorises a withdrawal, however well it reads")
    func directionGuard() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let imbalance = try #require(model.addAccount(name: "Imbalance-AUD", type: .bank))
        let refunds = try #require(model.addAccount(name: "Refunds", type: .income))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let subs = try #require(model.addAccount(name: "Subscriptions", type: .expense))

        // The learned example is a deposit (money in).
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_000_000),
                                 description: "Acme Refund", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("50"), memo: "ACME REFUND CREDIT"),
            SplitInput(accountID: refunds, value: dec("-50"))])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_100_000),
                                 description: "Woolworths", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-80"), memo: "WOOLWORTHS SYDNEY"),
            SplitInput(accountID: groceries, value: dec("80"))])
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_200_000),
                                 description: "Netflix", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-20"), memo: "NETFLIX COM SUBSCRIPTION"),
            SplitInput(accountID: subs, value: dec("20"))])

        // Same narrative, but money going *out*.
        _ = try model.addTransaction(
            date: Date(timeIntervalSince1970: 2_000_000),
            description: "ACME REFUND CREDIT 999", currency: .aud, splits: [
                SplitInput(accountID: bank, value: dec("-70")),
                SplitInput(accountID: imbalance, value: dec("70"))])

        #expect(model.smartCategoryPlans(for: model.uncategorizedItems()).isEmpty)
    }

    @Test("Plain assignments move the uncategorised leg; unknown ids are ignored")
    func applyAssignments() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let target = try f.model.addTransaction(
            date: Date(timeIntervalSince1970: 2_000_000),
            description: "Mystery Shop", currency: .aud, splits: [
                SplitInput(accountID: f.bank, value: dec("-25")),
                SplitInput(accountID: f.imbalance, value: dec("25"))])
        let book = try #require(f.model.book)
        let imbalanceLeg = try #require(book.splits(for: book.account(with: f.imbalance)!).first)

        let applied = f.model.applyCategorization(
            plans: [],
            assignments: [imbalanceLeg.guid: f.groceries, GncGUID.random(): f.subs])
        #expect(applied == 1)
        #expect(imbalanceLeg.account?.guid == f.groceries)
        let txn = try #require(book.transaction(with: target))
        #expect(txn.isBalanced)
        #expect(f.model.uncategorizedItems().isEmpty)

        // Nothing to do at all: zero applied.
        #expect(f.model.applyCategorization(plans: [], assignments: [:]) == 0)
    }

    @Test("Tokenisation keeps payee words and drops noise: numbers, dates, filler")
    func tokenisation() {
        #expect(AppModel.significantTokens("PayPal *DigiDirect 12345")
                == ["paypal", "digidirect"])
        // Month tokens — bare, with a two- and four-digit year — are date noise.
        #expect(AppModel.significantTokens("VAP DST JAN23") == ["vap", "dst"])
        #expect(AppModel.significantTokens("DIVIDEND APR2023 PAYMENT")
                == ["dividend", "payment"])
        #expect(AppModel.significantTokens("MAY") == [])
        // Structural filler and single characters go; short real words stay.
        #expect(AppModel.significantTokens("Transfer to the ANZ account of X")
                == ["transfer", "anz", "account"])
        #expect(AppModel.significantTokens("") == [])
        #expect(AppModel.significantTokens("1234 5678") == [])
    }
}
