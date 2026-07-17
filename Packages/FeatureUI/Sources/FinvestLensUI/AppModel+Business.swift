//
//  AppModel+Business.swift
//  FinvestLens — FeatureUI
//
//  The app-model bridge to the business engine (`FR-BUS-*`): create and manage
//  customers/vendors/employees, invoices/bills, tax tables and terms, post to
//  A/R–A/P, take payments, and read aging — each as one undoable edit.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The book's own company details, used to head printed invoices and statements
/// (GnuCash's *File ▸ Properties ▸ Business*). Stored in the book KVP so it
/// round-trips with the document.
public struct CompanyInfo: Codable, Equatable, Sendable {
    public var name: String = ""
    public var contact: String = ""
    public var addressLine1: String = ""
    public var addressLine2: String = ""
    public var phone: String = ""
    public var email: String = ""
    public var website: String = ""
    public var taxID: String = ""

    public init() {}

    /// Whether any field is filled — an empty company writes no slot.
    public var isEmpty: Bool { self == CompanyInfo() }
}

@MainActor
extension AppModel {

    // MARK: Company information

    /// Replaces the book's company details as one undoable edit.
    public func updateCompanyInfo(_ info: CompanyInfo) {
        companyInfo = info
        commitKvpCollections(named: "Company Information")
    }

    // MARK: Directory

    public var businessCustomers: [Customer] { book?.customers ?? [] }
    public var businessVendors: [Vendor] { book?.vendors ?? [] }
    public var businessEmployees: [Employee] { book?.employees ?? [] }
    public var businessInvoices: [Invoice] { book?.invoices ?? [] }
    public var businessTaxTables: [TaxTable] { book?.taxTables ?? [] }
    public var businessTerms: [BillTerm] { book?.billTerms ?? [] }

    /// Resolves an owner reference from a type and the party's guid.
    public func businessOwner(type: OwnerType, id: GncGUID) -> BusinessOwner? {
        guard let book else { return nil }
        switch type {
        case .customer: return book.customer(with: id).map { .customer($0) }
        case .vendor: return book.vendor(with: id).map { .vendor($0) }
        case .employee: return book.employee(with: id).map { .employee($0) }
        case .job: return book.job(with: id).map { .job($0) }
        }
    }

    // MARK: Create parties

    @discardableResult
    public func addCustomer(id: String, name: String, address: BusinessAddress = BusinessAddress(),
                            terms: BillTerm? = nil, taxTable: TaxTable? = nil) -> GncGUID? {
        guard let book else { return nil }
        let customer = Customer(id: id, name: name, address: address,
                                currency: reportCurrency, terms: terms, taxTable: taxTable,
                                taxTableOverride: taxTable != nil)
        editingWholeBook(named: "Add Customer") { book.addCustomer(customer) }
        return customer.guid
    }

    @discardableResult
    public func addVendor(id: String, name: String, address: BusinessAddress = BusinessAddress(),
                          terms: BillTerm? = nil, taxTable: TaxTable? = nil) -> GncGUID? {
        guard let book else { return nil }
        let vendor = Vendor(id: id, name: name, address: address, currency: reportCurrency,
                            terms: terms, taxTable: taxTable, taxTableOverride: taxTable != nil)
        editingWholeBook(named: "Add Vendor") { book.addVendor(vendor) }
        return vendor.guid
    }

    @discardableResult
    public func addEmployee(id: String, username: String,
                            address: BusinessAddress = BusinessAddress()) -> GncGUID? {
        guard let book else { return nil }
        let employee = Employee(id: id, username: username, address: address, currency: reportCurrency)
        editingWholeBook(named: "Add Employee") { book.addEmployee(employee) }
        return employee.guid
    }

    public var businessJobs: [Job] { book?.jobs ?? [] }

    /// Creates a job under a customer or vendor.
    @discardableResult
    public func addJob(id: String, name: String, reference: String = "",
                       ownerType: OwnerType, ownerID: GncGUID) -> GncGUID? {
        guard let book, let owner = businessOwner(type: ownerType, id: ownerID),
              owner.type == .customer || owner.type == .vendor else { return nil }
        let job = Job(id: id, name: name, reference: reference, owner: owner)
        editingWholeBook(named: "Add Job") { book.addJob(job) }
        return job.guid
    }

    // MARK: Terms & tax tables

    @discardableResult
    public func addBillTerm(name: String, kind: BillTerm.Kind = .days,
                            dueDays: Int) -> GncGUID? {
        guard let book else { return nil }
        let term = BillTerm(name: name, kind: kind, dueDays: dueDays)
        editingWholeBook(named: "Add Billing Term") { book.addBillTerm(term) }
        return term.guid
    }

    @discardableResult
    public func addTaxTable(name: String, accountID: GncGUID, percentage: Decimal) -> GncGUID? {
        guard let book, let account = book.account(with: accountID) else { return nil }
        let table = TaxTable(name: name, entries: [
            TaxTableEntry(account: account, kind: .percentage, amount: percentage)])
        editingWholeBook(named: "Add Tax Table") { book.addTaxTable(table) }
        return table.guid
    }

    // MARK: Invoices

    /// One line for ``createInvoice``.
    public struct InvoiceLineInput: Sendable {
        public var accountID: GncGUID
        public var description: String
        public var quantity: Decimal
        public var price: Decimal
        public var taxable: Bool
        public var taxTableID: GncGUID?
        public init(accountID: GncGUID, description: String = "", quantity: Decimal = 1,
                    price: Decimal, taxable: Bool = false, taxTableID: GncGUID? = nil) {
            self.accountID = accountID; self.description = description
            self.quantity = quantity; self.price = price
            self.taxable = taxable; self.taxTableID = taxTableID
        }
    }

    /// Creates an unposted invoice/bill/voucher for an owner and returns its id.
    @discardableResult
    public func createInvoice(id: String, kind: InvoiceKind, ownerType: OwnerType,
                              ownerID: GncGUID, dateOpened: Date = Date(),
                              lines: [InvoiceLineInput]) -> GncGUID? {
        guard let book, let owner = businessOwner(type: ownerType, id: ownerID) else { return nil }
        let entries = lines.compactMap { line -> InvoiceEntry? in
            guard let account = book.account(with: line.accountID) else { return nil }
            let table = line.taxTableID.flatMap { book.taxTable(with: $0) }
            return InvoiceEntry(entryDescription: line.description, account: account,
                                quantity: line.quantity, price: line.price,
                                taxable: line.taxable, taxTable: table)
        }
        let invoice = Invoice(id: id, kind: kind, owner: owner, dateOpened: dateOpened,
                              terms: owner.terms, currency: reportCurrency, entries: entries)
        editingWholeBook(named: "Create Invoice") { book.addInvoice(invoice) }
        return invoice.guid
    }

    /// Posts an invoice to its A/R (invoice) or A/P (bill/voucher) account.
    @discardableResult
    public func postInvoice(_ invoiceID: GncGUID, to accountID: GncGUID? = nil,
                            postDate: Date = Date()) -> Bool {
        guard let book, let invoice = book.invoice(with: invoiceID) else { return false }
        let account = accountID.flatMap { book.account(with: $0) }
            ?? (invoice.kind == .invoice ? book.defaultReceivable : book.defaultPayable)
        guard let account else { return false }
        var ok = false
        editingWholeBook(named: "Post Invoice") {
            ok = (try? book.postInvoice(invoice, to: account, postDate: postDate)) != nil
        }
        return ok
    }

    public func unpostInvoice(_ invoiceID: GncGUID) {
        guard let book, let invoice = book.invoice(with: invoiceID) else { return }
        editingWholeBook(named: "Unpost Invoice") { book.unpostInvoice(invoice) }
    }

    /// The amount still owed on an invoice.
    public func outstanding(_ invoiceID: GncGUID) -> Decimal {
        guard let book, let invoice = book.invoice(with: invoiceID) else { return 0 }
        return book.outstanding(invoice)
    }

    // MARK: Payments

    @discardableResult
    public func processPayment(ownerType: OwnerType, ownerID: GncGUID, amount: Decimal,
                               fromAccountID: GncGUID, on date: Date = Date()) -> Bool {
        guard let book, let owner = businessOwner(type: ownerType, id: ownerID),
              let bank = book.account(with: fromAccountID) else { return false }
        let posting = owner.postingAccountType == .receivable
            ? book.defaultReceivable : book.defaultPayable
        guard let posting else { return false }
        var ok = false
        editingWholeBook(named: "Process Payment") {
            ok = (try? book.processPayment(owner: owner, amount: amount, from: bank,
                                           to: posting, on: date)) != nil
        }
        return ok
    }

    // MARK: Aging

    /// Receivables (`receivable`) or payables aging, per owner, as of a date.
    public func aging(receivable: Bool, asOf: Date = Date())
        -> [(name: String, buckets: AgingBuckets)] {
        book?.agingByOwner(receivable: receivable, asOf: asOf) ?? []
    }
}
