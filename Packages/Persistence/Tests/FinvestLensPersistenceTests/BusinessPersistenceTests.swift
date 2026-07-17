//
//  BusinessPersistenceTests.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensPersistence

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@Suite("Business persistence")
struct BusinessPersistenceTests {

    /// A book with a customer, tax table, billing term, a posted invoice and a
    /// partial payment — the whole business graph.
    private func makeBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let ar = book.addAccount(Account(name: "A/R", type: .receivable, commodity: .aud))
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let sales = book.addAccount(Account(name: "Sales", type: .income, commodity: .aud))
        let gst = book.addAccount(Account(name: "GST", type: .liability, commodity: .aud))

        let net30 = book.addBillTerm(BillTerm(name: "Net 30", kind: .days, dueDays: 30))
        let gstTable = book.addTaxTable(TaxTable(name: "GST", entries: [
            TaxTableEntry(account: gst, kind: .percentage, amount: dec("10"))]))
        let customer = book.addCustomer(Customer(id: "C1", name: "Acme",
            address: BusinessAddress(name: "Acme Pty Ltd", line1: "1 Test St"),
            currency: .aud, terms: net30, taxTable: gstTable))

        let invoice = Invoice(id: "INV-1", kind: .invoice, owner: .customer(customer),
            terms: net30, currency: .aud, entries: [
                InvoiceEntry(entryDescription: "Widget", account: sales, quantity: dec("2"),
                             price: dec("50"), taxable: true, taxTable: gstTable)])
        book.addInvoice(invoice)
        try! book.postInvoice(invoice, to: ar, postDate: Date(timeIntervalSince1970: 1_700_000_000))
        try! book.processPayment(owner: .customer(customer), amount: dec("60"),
                                 from: bank, to: ar, on: Date(timeIntervalSince1970: 1_700_500_000))
        return book
    }

    @Test("The business graph survives a write/read round-trip")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = makeBook()
        try SQLiteDocumentStore(path: url.path).write(original)
        let book = try SQLiteDocumentStore(path: url.path).read()

        // Collections preserved.
        #expect(book.customers.count == 1)
        #expect(book.billTerms.count == 1)
        #expect(book.taxTables.count == 1)
        #expect(book.invoices.count == 1)

        let customer = try #require(book.customers.first)
        #expect(customer.name == "Acme")
        #expect(customer.address.name == "Acme Pty Ltd")
        #expect(customer.terms?.name == "Net 30")            // term reference resolved
        #expect(customer.taxTable?.name == "GST")            // tax-table reference resolved

        let invoice = try #require(book.invoices.first)
        #expect(invoice.id == "INV-1")
        #expect(invoice.total == dec("110"))                 // 100 + 10% GST
        #expect(invoice.isPosted)
        // The owner reference resolved back to the same customer object.
        #expect(invoice.owner.guid == customer.guid)
        // The entry's account and tax-table references resolved.
        #expect(invoice.entries.first?.account === book.accounts.first { $0.name == "Sales" })
        #expect(invoice.entries.first?.taxTable?.name == "GST")

        // The posting, lot and payment survived: 60 paid, 50 still outstanding.
        #expect(invoice.postedTransaction != nil)
        #expect(invoice.postedLot != nil)
        #expect(book.outstanding(invoice) == dec("50"))
        // The A/R account balance agrees.
        let ar = try #require(book.accounts.first { $0.type == .receivable })
        #expect(book.balance(of: ar).amount == dec("50"))
    }
}
