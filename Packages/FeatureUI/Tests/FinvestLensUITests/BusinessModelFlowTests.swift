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
import FinvestLensInterchange
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

    @Test("The whole-book GnuCash-XML snapshot (used by undo) preserves business")
    func wholeBookSnapshotRoundTrips() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let ar = try #require(model.addAccount(name: "A/R", type: .receivable))
        let sales = try #require(model.addAccount(name: "Sales", type: .income))
        let customer = try #require(model.addCustomer(id: "C1", name: "Acme"))
        let invoice = try #require(model.createInvoice(
            id: "INV-1", kind: .invoice, ownerType: .customer, ownerID: customer,
            lines: [.init(accountID: sales, price: dec("100"))]))
        #expect(model.postInvoice(invoice, to: ar))

        // This is exactly what whole-book undo snapshots and restores.
        let snapshot = try #require(model.gnuCashExportData())
        let restored = try FinvestLensInterchange.GnuCashXMLImporter.importBook(from: snapshot).book
        #expect(restored.customers.first?.name == "Acme")
        #expect(restored.invoices.first?.isPosted == true)
        // No tax table on this line, so the $100 invoice is fully outstanding.
        #expect(restored.outstanding(restored.invoices.first!) == dec("100"))
    }

    @Test("The receivable-aging report builds a bucketed table")
    func agingReportDocument() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let ar = try #require(model.addAccount(name: "A/R", type: .receivable))
        let sales = try #require(model.addAccount(name: "Sales", type: .income))
        let customer = try #require(model.addCustomer(id: "C1", name: "Acme"))
        let invoice = try #require(model.createInvoice(
            id: "INV-1", kind: .invoice, ownerType: .customer, ownerID: customer,
            lines: [.init(accountID: sales, price: dec("500"))]))
        #expect(model.postInvoice(invoice, to: ar))

        let config = ReportConfiguration(kind: ReportKind.receivableAging.rawValue,
                                         period: .allTime)
        let document = try #require(model.reportDocument(for: config))
        #expect(document.title == "Receivable Aging")
        let section = try #require(document.sections.first)
        #expect(section.columns == ["Current", "31–60", "61–90", "91+", "Total"])
        #expect(section.rows.first?.label == "Acme")
        // Acme's $500 shows in the total column and sums in columnTotals.
        #expect(section.rows.first?.amounts?.last == dec("500"))
        #expect(section.columnTotals?.amounts.last == dec("500"))
    }

    @Test("A job is created under a customer and reloads from disk")
    func jobsAndCompanyInfoPersist() async throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let customer = try #require(model.addCustomer(id: "C1", name: "Acme"))
        _ = try #require(model.addJob(id: "J1", name: "Website", ownerType: .customer, ownerID: customer))
        #expect(model.businessJobs.first?.name == "Website")
        #expect(model.businessJobs.first?.owner.displayName == "Acme")

        var info = CompanyInfo()
        info.name = "My Studio"; info.email = "hi@studio.example"; info.taxID = "ABN 123"
        model.updateCompanyInfo(info)
        #expect(model.companyInfo.name == "My Studio")
        try model.save()
        model.close()

        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.businessJobs.first?.name == "Website")
        #expect(reopened.companyInfo.name == "My Studio")
        #expect(reopened.companyInfo.taxID == "ABN 123")
    }

    @Test("The customer-summary report totals invoiced, paid, and outstanding")
    func customerSummaryReport() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let ar = try #require(model.addAccount(name: "A/R", type: .receivable))
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let sales = try #require(model.addAccount(name: "Sales", type: .income))
        let customer = try #require(model.addCustomer(id: "C1", name: "Acme"))
        let invoice = try #require(model.createInvoice(
            id: "INV-1", kind: .invoice, ownerType: .customer, ownerID: customer,
            lines: [.init(accountID: sales, price: dec("400"))]))
        #expect(model.postInvoice(invoice, to: ar))
        #expect(model.processPayment(ownerType: .customer, ownerID: customer,
                                     amount: dec("150"), fromAccountID: bank))

        let config = ReportConfiguration(kind: ReportKind.customerSummary.rawValue, period: .allTime)
        let document = try #require(model.reportDocument(for: config))
        #expect(document.title == "Customer Summary")
        let row = try #require(document.sections.first?.rows.first)
        #expect(row.label == "Acme")
        // Invoiced 400, paid 150, outstanding 250.
        #expect(row.amounts == [dec("400"), dec("150"), dec("250")])
    }

    @Test("The vendor-summary report totals billed, paid, and outstanding")
    func vendorSummaryReport() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let ap = try #require(model.addAccount(name: "A/P", type: .payable))
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let expense = try #require(model.addAccount(name: "Supplies", type: .expense))
        let vendor = try #require(model.addVendor(id: "V1", name: "Globex"))
        let bill = try #require(model.createInvoice(
            id: "BILL-1", kind: .bill, ownerType: .vendor, ownerID: vendor,
            lines: [.init(accountID: expense, price: dec("400"))]))
        #expect(model.postInvoice(bill, to: ap))
        #expect(model.processPayment(ownerType: .vendor, ownerID: vendor,
                                     amount: dec("150"), fromAccountID: bank))

        let config = ReportConfiguration(kind: ReportKind.vendorSummary.rawValue, period: .allTime)
        let document = try #require(model.reportDocument(for: config))
        #expect(document.title == "Vendor Summary")
        #expect(document.sections.first?.columns?.first == "Billed")
        let row = try #require(document.sections.first?.rows.first)
        #expect(row.label == "Globex")
        // Billed 400, paid 150, outstanding 250.
        #expect(row.amounts == [dec("400"), dec("150"), dec("250")])
    }

    @Test("Unbilled time & mileage gathers onto a customer invoice and marks entries billed (FR-PLAN-14)")
    func billableToInvoice() async throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)

        let ar = try #require(model.addAccount(name: "A/R", type: .receivable))
        let sales = try #require(model.addAccount(name: "Consulting Income", type: .income))
        let customer = try #require(model.addCustomer(id: "C1", name: "Acme"))

        model.addBillableEntry(BillableEntry(kind: .time, date: Date(timeIntervalSince1970: 0),
                                             customerID: customer, detail: "Design",
                                             quantity: dec("3"), rate: dec("120"),
                                             incomeAccountID: sales))
        model.addBillableEntry(BillableEntry(kind: .mileage, date: Date(timeIntervalSince1970: 1000),
                                             customerID: customer, detail: "Site visit",
                                             quantity: dec("50"), rate: dec("0.85"),
                                             incomeAccountID: sales))
        #expect(model.unbilledEntries(forCustomer: customer).count == 2)

        let invoiceID = try #require(model.createInvoiceFromUnbilled(
            customerID: customer, invoiceNumber: "INV-100"))
        // Both entries are now billed; none remain to bill.
        #expect(model.unbilledEntries(forCustomer: customer).isEmpty)
        let allBilled = model.billableEntries.allSatisfy { $0.billed }
        #expect(allBilled)

        // The invoice totals 3×120 + 50×0.85 = 360 + 42.50 = 402.50.
        let book = try #require(model.book)
        let invoice = try #require(book.invoice(with: invoiceID))
        #expect(invoice.total == dec("402.50"))
        #expect(invoice.entries.count == 2)
        #expect(model.postInvoice(invoiceID, to: ar))

        // Entries survive save/reload with their billed flag.
        try model.save(); model.close()
        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.billableEntries.count == 2)
        let reopenedBilled = reopened.billableEntries.allSatisfy { $0.billed }
        #expect(reopenedBilled)
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
