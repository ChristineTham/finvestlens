//
//  BusinessModelFlowTests.swift
//  FinvestLens — FeatureUI
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
@Suite("Business flow (AppModel)")
struct BusinessModelFlowTests {

    @Test("Create → post → pay an invoice through the app model")
    func endToEnd() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let ar = try #require(model.addAccount(name: "A/R", type: .receivable))
        _ = try #require(model.addAccount(name: "A/P", type: .payable))
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let sales = try #require(model.addAccount(name: "Sales", type: .income))
        let gstAcct = try #require(model.addAccount(name: "GST", type: .liability))

        let net30 = try #require(model.addBillTerm(name: "Net 30", dueDays: 30))
        let gst = try #require(model.addTaxTable(name: "GST", accountID: gstAcct,
                                                 percentage: dec("10")))
        let term = model.book?.billTerm(with: net30)
        let table = model.book?.taxTable(with: gst)
        let customer = try #require(model.addCustomer(id: "C1", name: "Acme",
                                                      terms: term, taxTable: table))

        let invoice = try #require(model.createInvoice(
            id: "INV-1", kind: .invoice, ownerType: .customer, ownerID: customer,
            lines: [.init(accountID: sales, description: "Widget", quantity: dec("2"),
                          price: dec("50"), taxable: true, taxTableID: gst)]))

        // Post it: A/R now shows 110 (100 + 10% GST).
        #expect(model.postInvoice(invoice, to: ar))
        #expect(model.outstanding(invoice) == dec("110"))
        #expect(model.book?.balance(of: model.book!.account(with: ar)!).amount == dec("110"))

        // Pay 60: 50 remains, aging shows it as current.
        #expect(model.processPayment(ownerType: .customer, ownerID: customer,
                                     amount: dec("60"), fromAccountID: bank))
        #expect(model.outstanding(invoice) == dec("50"))

        let aging = model.aging(receivable: true)
        #expect(aging.first?.name == "Acme")
        #expect(aging.first?.buckets.total == dec("50"))
    }

    @Test("A created invoice persists on save and reloads")
    func savesAndReloads() async throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let ar = try #require(model.addAccount(name: "A/R", type: .receivable))
        let sales = try #require(model.addAccount(name: "Sales", type: .income))
        let customer = try #require(model.addCustomer(id: "C1", name: "Acme"))
        let invoice = try #require(model.createInvoice(
            id: "INV-1", kind: .invoice, ownerType: .customer, ownerID: customer,
            lines: [.init(accountID: sales, price: dec("100"))]))
        #expect(model.postInvoice(invoice, to: ar))
        try model.save()
        model.close()

        // Reopen from disk (SQLite): the business graph is intact.
        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.businessCustomers.first?.name == "Acme")
        #expect(reopened.outstanding(invoice) == dec("100"))
    }
}
