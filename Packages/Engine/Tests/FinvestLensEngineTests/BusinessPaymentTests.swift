//
//  BusinessPaymentTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Business payments and aging")
struct BusinessPaymentTests {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func fixture() -> (Book, ar: Account, bank: Account, sales: Account, Customer) {
        let book = Book(baseCurrency: .aud)
        let ar = Account(name: "A/R", type: .receivable, commodity: .aud)
        let bank = Account(name: "Bank", type: .bank, commodity: .aud)
        let sales = Account(name: "Sales", type: .income, commodity: .aud)
        for a in [ar, bank, sales] { book.addAccount(a) }
        let customer = book.addCustomer(Customer(id: "C1", name: "Acme", currency: .aud))
        return (book, ar, bank, sales, customer)
    }

    private func invoice(_ book: Book, _ customer: Customer, _ sales: Account,
                         _ ar: Account, id: String, amount: String, posted: Date) throws -> Invoice {
        let inv = Invoice(id: id, kind: .invoice, owner: .customer(customer), currency: .aud,
                          entries: [InvoiceEntry(account: sales, quantity: dec("1"),
                                                 price: dec(amount))])
        book.addInvoice(inv)
        try book.postInvoice(inv, to: ar, postDate: posted, calendar: utc)
        return inv
    }

    @Test("A full payment clears the invoice and moves cash")
    func fullPayment() throws {
        let (book, ar, bank, sales, customer) = fixture()
        let inv = try invoice(book, customer, sales, ar, id: "INV-1", amount: "100",
                              posted: date(2026, 1, 1))
        #expect(book.outstanding(inv) == dec("100"))

        let txn = try book.processPayment(owner: .customer(customer), amount: dec("100"),
                                          from: bank, to: ar, on: date(2026, 1, 15))
        #expect(txn.splits.reduce(Decimal(0)) { $0 + $1.value } == 0)
        #expect(book.balance(of: bank).amount == dec("100"))   // cash in
        #expect(book.balance(of: ar).amount == 0)              // receivable cleared
        #expect(book.outstanding(inv) == 0)
    }

    @Test("A partial payment leaves a balance; the oldest invoice pays first")
    func partialAndOldestFirst() throws {
        let (book, ar, bank, sales, customer) = fixture()
        let inv1 = try invoice(book, customer, sales, ar, id: "INV-1", amount: "100",
                               posted: date(2026, 1, 1))
        let inv2 = try invoice(book, customer, sales, ar, id: "INV-2", amount: "200",
                               posted: date(2026, 2, 1))

        // Pay 150: clears INV-1 (100), leaves 50 on INV-2 (200).
        try book.processPayment(owner: .customer(customer), amount: dec("150"),
                                from: bank, to: ar, on: date(2026, 2, 15))
        #expect(book.outstanding(inv1) == 0)
        #expect(book.outstanding(inv2) == dec("150"))
        #expect(book.balance(of: ar).amount == dec("150"))
    }

    @Test("Overpayment opens a pre-payment credit")
    func overpayment() throws {
        let (book, ar, bank, sales, customer) = fixture()
        let inv = try invoice(book, customer, sales, ar, id: "INV-1", amount: "100",
                              posted: date(2026, 1, 1))
        try book.processPayment(owner: .customer(customer), amount: dec("120"),
                                from: bank, to: ar, on: date(2026, 1, 15))
        #expect(book.outstanding(inv) == 0)
        // A/R is now a 20 credit (we owe the customer); a pre-payment lot holds it.
        #expect(book.balance(of: ar).amount == dec("-20"))
        #expect(book.lots(in: ar).contains { $0.title == "Pre-payment" && $0.balance == dec("-20") })
    }

    @Test("Aging buckets open invoices by how far past due")
    func aging() throws {
        let (book, ar, _, sales, customer) = fixture()
        let net0 = book.addBillTerm(BillTerm(name: "Due on receipt", kind: .days, dueDays: 0))
        func post(_ id: String, _ amount: String, _ posted: Date) throws {
            let inv = Invoice(id: id, kind: .invoice, owner: .customer(customer), terms: net0,
                              currency: .aud, entries: [InvoiceEntry(account: sales,
                                                                     price: dec(amount))])
            book.addInvoice(inv)
            try book.postInvoice(inv, to: ar, postDate: posted, calendar: utc)
        }
        let asOf = date(2026, 4, 1)
        try post("A", "100", date(2026, 3, 20))   // 12 days overdue → current
        try post("B", "200", date(2026, 2, 20))   // 40 days → 31-60
        try post("C", "400", date(2026, 1, 20))   // 71 days → 61-90
        try post("D", "800", date(2025, 12, 1))   // 121 days → 91+

        let buckets = book.aging(forOwner: customer.guid, asOf: asOf, calendar: utc)
        #expect(buckets.current == dec("100"))
        #expect(buckets.days31to60 == dec("200"))
        #expect(buckets.days61to90 == dec("400"))
        #expect(buckets.over90 == dec("800"))
        #expect(buckets.total == dec("1500"))
    }

    @Test("Per-owner aging ranks the biggest debtors first")
    func agingByOwner() throws {
        let (book, ar, _, sales, customer) = fixture()
        _ = try invoice(book, customer, sales, ar, id: "INV-1", amount: "100",
                        posted: date(2026, 1, 1))
        let big = book.addCustomer(Customer(id: "C2", name: "BigCo", currency: .aud))
        _ = try invoice(book, big, sales, ar, id: "INV-2", amount: "500", posted: date(2026, 1, 1))

        let rows = book.agingByOwner(receivable: true, asOf: date(2026, 1, 10), calendar: utc)
        #expect(rows.map(\.name) == ["BigCo", "Acme"])
        #expect(rows.first?.buckets.total == dec("500"))
    }
}
