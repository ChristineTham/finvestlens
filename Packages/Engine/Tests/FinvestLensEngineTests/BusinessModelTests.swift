//
//  BusinessModelTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Business model")
struct BusinessModelTests {

    private func book() -> (Book, income: Account, gst: Account, expense: Account) {
        let book = Book(baseCurrency: .aud)
        let income = Account(name: "Sales", type: .income, commodity: .aud)
        let gst = Account(name: "GST Collected", type: .liability, commodity: .aud)
        let expense = Account(name: "Supplies", type: .expense, commodity: .aud)
        book.addAccount(income); book.addAccount(gst); book.addAccount(expense)
        return (book, income, gst, expense)
    }

    private func gstTable(_ account: Account, percent: String = "10") -> TaxTable {
        TaxTable(name: "GST", entries: [TaxTableEntry(account: account,
                                                      kind: .percentage, amount: dec(percent))])
    }

    @Test("Entry totals: gross, percentage discount, percentage tax")
    func entryPercentage() {
        let (_, income, gst, _) = book()
        let entry = InvoiceEntry(entryDescription: "Widget", account: income,
                                 quantity: dec("2"), price: dec("50"),
                                 discount: dec("10"), discountType: .percentage,
                                 taxable: true, taxTable: gstTable(gst))
        #expect(entry.gross == dec("100"))
        #expect(entry.discountAmount == dec("10"))
        #expect(entry.subtotal == dec("90"))
        #expect(entry.tax == dec("9"))       // 10% of 90
        #expect(entry.total == dec("99"))
    }

    @Test("Entry totals: value discount and a flat value tax")
    func entryValue() {
        let (_, income, gst, _) = book()
        let entry = InvoiceEntry(account: income, quantity: dec("2"), price: dec("50"),
                                 discount: dec("15"), discountType: .value,
                                 taxable: true,
                                 taxTable: TaxTable(name: "Levy", entries: [
                                    TaxTableEntry(account: gst, kind: .value, amount: dec("5"))]))
        #expect(entry.subtotal == dec("85"))   // 100 − 15
        #expect(entry.tax == dec("5"))         // flat
        #expect(entry.total == dec("90"))
    }

    @Test("Tax-inclusive pricing backs the tax out of the price (GnuCash)")
    func entryTaxIncluded() {
        let (_, income, gst, _) = book()
        // Price 110 quoted tax-inclusive with a 10% tax → pre-tax 100, tax 10.
        let entry = InvoiceEntry(account: income, quantity: dec("1"), price: dec("110"),
                                 taxable: true, taxIncluded: true, taxTable: gstTable(gst))
        #expect(entry.subtotal == dec("100"))
        #expect(entry.tax == dec("10"))
        #expect(entry.total == dec("110"))
    }

    @Test("A non-taxable entry has no tax even with a table set")
    func nonTaxable() {
        let (_, income, gst, _) = book()
        let entry = InvoiceEntry(account: income, quantity: dec("3"), price: dec("20"),
                                 taxable: false, taxTable: gstTable(gst))
        #expect(entry.subtotal == dec("60"))
        #expect(entry.tax == dec("0"))
    }

    @Test("Invoice sums entries and groups subtotals and tax by account")
    func invoiceTotals() {
        let (book, income, gst, _) = book()
        let consulting = Account(name: "Consulting", type: .income, commodity: .aud)
        book.addAccount(consulting)
        let customer = Customer(id: "0001", name: "Acme", currency: .aud)
        book.addCustomer(customer)

        let table = gstTable(gst)
        let invoice = Invoice(id: "INV-1", kind: .invoice, owner: .customer(customer),
                              currency: .aud, entries: [
            InvoiceEntry(account: income, quantity: dec("2"), price: dec("50"),
                         taxable: true, taxTable: table),        // 100 + 10 GST
            InvoiceEntry(account: consulting, quantity: dec("1"), price: dec("200"),
                         taxable: true, taxTable: table),        // 200 + 20 GST
            InvoiceEntry(account: income, quantity: dec("1"), price: dec("30"),
                         taxable: false),                        // 30, no GST
        ])
        book.addInvoice(invoice)

        #expect(invoice.subtotal == dec("330"))     // 100 + 200 + 30
        #expect(invoice.taxTotal == dec("30"))      // 10 + 20
        #expect(invoice.total == dec("360"))

        // Sales income is two lines (100 + 30 = 130); consulting is 200.
        let subs = invoice.subtotalsByAccount()
        #expect(subs.first { $0.account === income }?.amount == dec("130"))
        #expect(subs.first { $0.account === consulting }?.amount == dec("200"))
        // All GST collects into the one liability account.
        let taxes = invoice.taxByAccount()
        #expect(taxes.count == 1)
        #expect(taxes.first?.account === gst)
        #expect(taxes.first?.amount == dec("30"))
    }

    @Test("Billing terms compute the due date")
    func billTermDueDate() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let post = cal.date(from: DateComponents(year: 2026, month: 3, day: 10))!

        let net30 = BillTerm(name: "Net 30", kind: .days, dueDays: 30)
        #expect(net30.dueDate(postedOn: post, calendar: cal)
                == cal.date(from: DateComponents(year: 2026, month: 4, day: 9)))

        // Proximo: due the 15th of the following month.
        let proximo = BillTerm(name: "15th prox", kind: .proximo, dueDays: 15)
        #expect(proximo.dueDate(postedOn: post, calendar: cal)
                == cal.date(from: DateComponents(year: 2026, month: 4, day: 15)))

        // Cutoff: a post after the cutoff day rolls to the month after next.
        let cutoff5 = BillTerm(name: "15th prox, cut 5", kind: .proximo, dueDays: 15, cutoff: 5)
        #expect(cutoff5.dueDate(postedOn: post, calendar: cal)     // day 10 > cutoff 5
                == cal.date(from: DateComponents(year: 2026, month: 5, day: 15)))

        // Due day clamps to the real last day of the target month (April has 30).
        let endProx = BillTerm(name: "31st prox", kind: .proximo, dueDays: 31)
        #expect(endProx.dueDate(postedOn: post, calendar: cal)
                == cal.date(from: DateComponents(year: 2026, month: 4, day: 30)))
    }

    @Test("Owner resolves nature: customers receive, vendors pay")
    func ownerNature() {
        let customer = Customer(id: "C1", name: "Acme", currency: .aud)
        let vendor = Vendor(id: "V1", name: "Supplies Co", currency: .aud)
        #expect(BusinessOwner.customer(customer).postingAccountType == .receivable)
        #expect(BusinessOwner.vendor(vendor).postingAccountType == .payable)
        // A job inherits its owner's nature and currency.
        let job = Job(id: "J1", name: "Website", owner: .customer(customer))
        #expect(BusinessOwner.job(job).postingAccountType == .receivable)
        #expect(BusinessOwner.job(job).displayName == "Website")
    }

    @Test("Book registers and looks up business objects")
    func registration() {
        let (book, _, _, _) = book()
        let customer = Customer(id: "C1", name: "Acme", currency: .aud)
        book.addCustomer(customer)
        #expect(book.customer(with: customer.guid) === customer)
        #expect(book.customers.count == 1)
    }
}
