//
//  ReportDocumentsTests.swift
//  FinvestLens — FeatureUI
//
//  Printable document builders for the interactive reports (FR-RPT-05).
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
@Suite("Report documents (FR-RPT-05)")
struct ReportDocumentsTests {

    @Test("The transactions document carries the postings and opening/closing figures")
    func transactionsDocument() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        try model.addTransaction(date: Date(timeIntervalSince1970: 1000), description: "Cafe",
                                 currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-8")),
            SplitInput(accountID: food, value: dec("8"))])

        let doc = try #require(model.transactionsDocument(
            accountID: bank, from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10_000)))
        #expect(doc.title == "Transactions — Bank")
        #expect(doc.sections.first?.rows.count == 1)
        #expect(doc.sections.first?.columns == ["Amount", "Balance"])
        // Printable form renders without crashing.
        #expect(ReportExport.pdf(doc.printable) != nil)
    }

    @Test("The reconciliation document totals funds in/out and balances")
    func reconcileDocument() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        try model.addTransaction(date: Date(timeIntervalSince1970: 1000), description: "Pay",
                                 currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("500")),
            SplitInput(accountID: salary, value: dec("-500"))])

        let doc = try #require(model.reconcileDocument(accountID: bank, asOf: Date()))
        #expect(doc.title == "Reconciliation — Bank")
        #expect(doc.sections.contains { $0.title == "Funds In" })
    }

    @Test("Investment-heavy documents return nil on a book with no securities")
    func emptyBookYieldsNil() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = try #require(model.addAccount(name: "Bank", type: .bank))

        #expect(model.portfolioDocument() == nil)
        #expect(model.investmentLotsDocument() == nil)
        #expect(model.priceHistoryDocument() == nil)
        // No realised disposals → capital-gains report has no lines, but the
        // document itself is still produced with a "no gains" note when there
        // are securities; with none at all it is nil.
        #expect(model.capitalGainsDocument() == nil)
    }
}
