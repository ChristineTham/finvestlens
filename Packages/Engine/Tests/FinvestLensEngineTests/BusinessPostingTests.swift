//
//  BusinessPostingTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }

@Suite("Business posting")
struct BusinessPostingTests {

    private func fixture() -> (Book, ar: Account, ap: Account, sales: Account,
                               gst: Account, supplies: Account) {
        let book = Book(baseCurrency: .aud)
        let ar = Account(name: "Accounts Receivable", type: .receivable, commodity: .aud)
        let ap = Account(name: "Accounts Payable", type: .payable, commodity: .aud)
        let sales = Account(name: "Sales", type: .income, commodity: .aud)
        let gst = Account(name: "GST", type: .liability, commodity: .aud)
        let supplies = Account(name: "Supplies", type: .expense, commodity: .aud)
        for a in [ar, ap, sales, gst, supplies] { book.addAccount(a) }
        return (book, ar, ap, sales, gst, supplies)
    }

    private func gstTable(_ account: Account) -> TaxTable {
        TaxTable(name: "GST", entries: [TaxTableEntry(account: account,
                                                      kind: .percentage, amount: dec("10"))])
    }

    @Test("Posting a customer invoice books a balanced A/R transaction")
    func postInvoice() throws {
        let (book, ar, _, sales, gst, _) = fixture()
        let customer = book.addCustomer(Customer(id: "C1", name: "Acme", currency: .aud))
        let invoice = Invoice(id: "INV-1", kind: .invoice, owner: .customer(customer),
                              currency: .aud, entries: [
            InvoiceEntry(account: sales, quantity: dec("2"), price: dec("50"),
                         taxable: true, taxTable: gstTable(gst)),
        ])
        book.addInvoice(invoice)

        let txn = try book.postInvoice(invoice, to: ar, postDate: day(0))

        // Balanced: +110 A/R − 100 sales − 10 GST = 0.
        #expect(txn.splits.reduce(Decimal(0)) { $0 + $1.value } == 0)
        #expect(txn.splits.first { $0.account === ar }?.value == dec("110"))
        #expect(txn.splits.first { $0.account === sales }?.value == dec("-100"))
        #expect(txn.splits.first { $0.account === gst }?.value == dec("-10"))

        // The A/R account now shows the customer owes 110, and the lot agrees.
        #expect(book.balance(of: ar).amount == dec("110"))
        #expect(invoice.isPosted)
        #expect(book.outstanding(invoice) == dec("110"))
        #expect(book.lots(in: ar).count == 1)
        #expect(invoice.postedLot?.balance == dec("110"))
    }

    @Test("The posting transaction carries the slots GnuCash's reports need")
    func postingCarriesBusinessSlots() throws {
        // GnuCash attributes a posting to its owner via the `gncInvoice` slot on
        // the *transaction* (gncInvoiceGetInvoiceFromTxn), not only the lot —
        // without it its aging/summary reports say "no suitable transactions".
        let (book, ar, _, sales, _, _) = fixture()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let post = cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let net30 = book.addBillTerm(BillTerm(name: "Net 30", kind: .days, dueDays: 30))
        let customer = book.addCustomer(Customer(id: "C1", name: "Acme",
                                                 currency: .aud, terms: net30))
        let invoice = Invoice(id: "INV-1", kind: .invoice, owner: .customer(customer),
                              terms: net30, currency: .aud,
                              entries: [InvoiceEntry(account: sales, price: dec("100"))])
        book.addInvoice(invoice)
        let txn = try book.postInvoice(invoice, to: ar, postDate: post, calendar: cal)

        #expect(txn.kvp["trans-txn-type"] == .string("I"))
        #expect(txn.kvp["gncInvoice"] == .frame(KvpFrame(["invoice-guid": .guid(invoice.guid)])))
        #expect(txn.kvp["trans-date-due"] == .date(invoice.dueDate!))
    }

    @Test("Posting a vendor bill books a balanced A/P transaction")
    func postBill() throws {
        let (book, _, ap, _, gst, supplies) = fixture()
        let vendor = book.addVendor(Vendor(id: "V1", name: "Supplies Co", currency: .aud))
        let bill = Invoice(id: "BILL-1", kind: .bill, owner: .vendor(vendor),
                           currency: .aud, entries: [
            InvoiceEntry(account: supplies, quantity: dec("1"), price: dec("200"),
                         taxable: true, taxTable: gstTable(gst)),
        ])
        book.addInvoice(bill)

        let txn = try book.postInvoice(bill, to: ap, postDate: day(0))
        #expect(txn.splits.reduce(Decimal(0)) { $0 + $1.value } == 0)
        // We owe 220: A/P is a liability, credit-normal → −220 raises it.
        #expect(txn.splits.first { $0.account === ap }?.value == dec("-220"))
        #expect(txn.splits.first { $0.account === supplies }?.value == dec("200"))
        #expect(txn.splits.first { $0.account === gst }?.value == dec("20"))
        #expect(book.outstanding(bill) == dec("220"))
    }

    @Test("Due date comes from the invoice's billing terms")
    func dueDateFromTerms() throws {
        let (book, ar, _, sales, _, _) = fixture()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let post = cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let net30 = book.addBillTerm(BillTerm(name: "Net 30", kind: .days, dueDays: 30))
        let customer = book.addCustomer(Customer(id: "C1", name: "Acme",
                                                 currency: .aud, terms: net30))
        let invoice = Invoice(id: "INV-1", kind: .invoice, owner: .customer(customer),
                              terms: net30, currency: .aud,
                              entries: [InvoiceEntry(account: sales, quantity: dec("1"),
                                                     price: dec("100"))])
        book.addInvoice(invoice)
        try book.postInvoice(invoice, to: ar, postDate: post, calendar: cal)
        #expect(invoice.dueDate == cal.date(from: DateComponents(year: 2026, month: 3, day: 31)))
    }

    @Test("Posting to the wrong account nature is refused")
    func wrongAccount() throws {
        let (book, _, ap, sales, _, _) = fixture()
        let customer = book.addCustomer(Customer(id: "C1", name: "Acme", currency: .aud))
        let invoice = Invoice(id: "INV-1", kind: .invoice, owner: .customer(customer),
                              currency: .aud,
                              entries: [InvoiceEntry(account: sales, price: dec("10"))])
        book.addInvoice(invoice)
        // An invoice must post to A/R, not A/P.
        #expect(throws: BusinessError.wrongPostingAccount) {
            try book.postInvoice(invoice, to: ap, postDate: day(0))
        }
    }

    @Test("Unposting removes the transaction and lot")
    func unpost() throws {
        let (book, ar, _, sales, gst, _) = fixture()
        let customer = book.addCustomer(Customer(id: "C1", name: "Acme", currency: .aud))
        let invoice = Invoice(id: "INV-1", kind: .invoice, owner: .customer(customer),
                              currency: .aud, entries: [
            InvoiceEntry(account: sales, quantity: dec("1"), price: dec("100"),
                         taxable: true, taxTable: gstTable(gst))])
        book.addInvoice(invoice)
        try book.postInvoice(invoice, to: ar, postDate: day(0))
        #expect(book.transactions.count == 1)

        book.unpostInvoice(invoice)
        #expect(book.transactions.isEmpty)
        #expect(book.lots.isEmpty)
        #expect(!invoice.isPosted)
        #expect(book.balance(of: ar).amount == 0)
    }
}
