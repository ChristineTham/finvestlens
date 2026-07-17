//
//  BusinessRoundTripTests.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensInterchange

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Business GnuCash-XML round-trip")
struct BusinessRoundTripTests {

    /// A book with the whole business graph and a posted, part-paid invoice.
    private func makeBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let ar = book.addAccount(Account(name: "Accounts Receivable", type: .receivable, commodity: .aud))
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let sales = book.addAccount(Account(name: "Sales", type: .income, commodity: .aud))
        let gst = book.addAccount(Account(name: "GST Collected", type: .liability, commodity: .aud))

        let net30 = book.addBillTerm(BillTerm(name: "Net 30", kind: .days, dueDays: 30))
        let gstTable = book.addTaxTable(TaxTable(name: "GST", entries: [
            TaxTableEntry(account: gst, kind: .percentage, amount: dec("10"))]))
        let customer = book.addCustomer(Customer(id: "000001", name: "Acme Pty Ltd",
            address: BusinessAddress(name: "Acme Pty Ltd", line1: "1 Test St", email: "ap@acme.test"),
            currency: .aud, terms: net30, taxTable: gstTable, taxTableOverride: true))

        let invoice = Invoice(id: "INV-1", kind: .invoice, owner: .customer(customer),
            terms: net30, currency: .aud, entries: [
                InvoiceEntry(entryDescription: "Widget", account: sales, quantity: dec("2"),
                             price: dec("50"), taxable: true, taxTable: gstTable)])
        book.addInvoice(invoice)
        try! book.postInvoice(invoice, to: ar,
                              postDate: Date(timeIntervalSince1970: 1_700_000_000))
        try! book.processPayment(owner: .customer(customer), amount: dec("60"),
                                 from: bank, to: ar, on: Date(timeIntervalSince1970: 1_700_500_000))
        return book
    }

    @Test("The business graph survives export → re-import")
    func roundTrip() throws {
        let xml = GnuCashXMLExporter.export(makeBook())
        let book = try GnuCashXMLImporter.importBook(from: xml).book

        #expect(book.billTerms.first?.name == "Net 30")
        #expect(book.billTerms.first?.dueDays == 30)
        #expect(book.taxTables.first?.name == "GST")
        #expect(book.taxTables.first?.totalPercentage == dec("10"))

        let customer = try #require(book.customers.first)
        #expect(customer.name == "Acme Pty Ltd")
        #expect(customer.id == "000001")
        #expect(customer.address.email == "ap@acme.test")
        #expect(customer.terms?.name == "Net 30")          // term reference
        #expect(customer.taxTable?.name == "GST")          // tax-table reference

        let invoice = try #require(book.invoices.first)
        #expect(invoice.kind == .invoice)
        #expect(invoice.owner.guid == customer.guid)       // owner reference
        #expect(invoice.total == dec("110"))               // 100 + 10% GST
        #expect(invoice.isPosted)
        #expect(invoice.entries.first?.account === book.accounts.first { $0.name == "Sales" })
        #expect(invoice.entries.first?.taxTable?.name == "GST")

        // The lot and its split membership survived, so the outstanding balance
        // (110 − 60 paid) is preserved.
        #expect(invoice.postedLot != nil)
        #expect(book.outstanding(invoice) == dec("50"))
        let ar = try #require(book.accounts.first { $0.type == .receivable })
        #expect(book.balance(of: ar).amount == dec("50"))
        #expect(book.lots(in: ar).contains { $0.title == "INV-1" })
    }

    @Test("A vendor bill round-trips on the A/P side")
    func billRoundTrip() throws {
        let book = Book(baseCurrency: .aud)
        let ap = book.addAccount(Account(name: "A/P", type: .payable, commodity: .aud))
        let supplies = book.addAccount(Account(name: "Supplies", type: .expense, commodity: .aud))
        let vendor = book.addVendor(Vendor(id: "V1", name: "Supplies Co", currency: .aud))
        let bill = Invoice(id: "BILL-1", kind: .bill, owner: .vendor(vendor), currency: .aud,
                           entries: [InvoiceEntry(account: supplies, quantity: dec("1"),
                                                  price: dec("200"))])
        book.addInvoice(bill)
        try book.postInvoice(bill, to: ap, postDate: Date(timeIntervalSince1970: 1_700_000_000))

        let xml = GnuCashXMLExporter.export(book)
        let reimported = try GnuCashXMLImporter.importBook(from: xml).book
        let reBill = try #require(reimported.invoices.first)
        #expect(reBill.kind == .bill)
        #expect(reBill.owner.type == .vendor)
        #expect(reimported.outstanding(reBill) == dec("200"))
    }
}
