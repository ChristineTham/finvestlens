//
//  Business.swift
//  FinvestLens — Engine
//
//  The business object graph (`FR-BUS-*`): customers, vendors, employees, jobs,
//  invoices/bills/vouchers and their line entries, billing terms and sales-tax
//  tables. Modelled on GnuCash's business engine (`gncCustomer`, `gncInvoice`,
//  `gncEntry`, …) so a book round-trips, and so an invoice's totals and its
//  posting to A/R match GnuCash line for line.
//
//  Posting an invoice to A/R/A/P, payments, and aging live in
//  `BusinessPosting.swift`; this file is the data model and the entry/invoice
//  arithmetic.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

// MARK: - Address

/// A postal/contact address, as carried by every owner.
public struct BusinessAddress: Hashable, Sendable, Codable {
    public var name: String
    public var line1: String
    public var line2: String
    public var line3: String
    public var line4: String
    public var phone: String
    public var fax: String
    public var email: String

    public init(name: String = "", line1: String = "", line2: String = "",
                line3: String = "", line4: String = "", phone: String = "",
                fax: String = "", email: String = "") {
        self.name = name; self.line1 = line1; self.line2 = line2
        self.line3 = line3; self.line4 = line4
        self.phone = phone; self.fax = fax; self.email = email
    }
}

// MARK: - Billing terms

/// A billing term: when an invoice falls due and any early-payment discount
/// (GnuCash `gncBillTerm`).
public final class BillTerm: Identifiable, @unchecked Sendable {
    /// How the due date is derived from the post date.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Due a fixed number of days after posting.
        case days
        /// Due on a day of the month in a following month (proximo).
        case proximo
    }

    public let guid: GncGUID
    public var name: String
    public var termDescription: String
    public var kind: Kind
    /// Days-to-due (`.days`) or day-of-month cutoff (`.proximo`).
    public var dueDays: Int
    /// Days within which the discount applies.
    public var discountDays: Int
    /// Early-payment discount, as a percentage.
    public var discountPercent: Decimal
    public var active: Bool

    public init(guid: GncGUID = .random(), name: String, termDescription: String = "",
                kind: Kind = .days, dueDays: Int = 0, discountDays: Int = 0,
                discountPercent: Decimal = 0, active: Bool = true) {
        self.guid = guid; self.name = name; self.termDescription = termDescription
        self.kind = kind; self.dueDays = dueDays; self.discountDays = discountDays
        self.discountPercent = discountPercent; self.active = active
    }

    /// The date an invoice posted on `postDate` falls due under this term.
    public func dueDate(postedOn postDate: Date, calendar: Calendar = .current) -> Date {
        switch kind {
        case .days:
            return calendar.date(byAdding: .day, value: dueDays, to: postDate) ?? postDate
        case .proximo:
            // Due on day `dueDays` of the next month.
            let day = min(max(dueDays, 1), 28)
            let startNextMonth = calendar.date(byAdding: .month, value: 1, to: postDate) ?? postDate
            var comps = calendar.dateComponents([.year, .month], from: startNextMonth)
            comps.day = day
            return calendar.date(from: comps) ?? postDate
        }
    }
}

// MARK: - Tax tables

/// One line of a sales-tax table: a rate or flat amount collected into an
/// account (GnuCash `gncTaxTableEntry`).
public struct TaxTableEntry: @unchecked Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// `amount` is a percentage of the taxable subtotal.
        case percentage
        /// `amount` is a flat value added per entry.
        case value
    }
    /// The account the tax is booked to (a liability for collected GST).
    public var account: Account
    public var kind: Kind
    public var amount: Decimal

    public init(account: Account, kind: Kind = .percentage, amount: Decimal) {
        self.account = account; self.kind = kind; self.amount = amount
    }
}

/// A named sales-tax table (GnuCash `gncTaxTable`).
public final class TaxTable: Identifiable, @unchecked Sendable {
    public let guid: GncGUID
    public var name: String
    public var entries: [TaxTableEntry]
    public var active: Bool

    public init(guid: GncGUID = .random(), name: String,
                entries: [TaxTableEntry] = [], active: Bool = true) {
        self.guid = guid; self.name = name; self.entries = entries; self.active = active
    }

    /// The combined percentage of all percentage entries (e.g. 10 for GST).
    public var totalPercentage: Decimal {
        entries.filter { $0.kind == .percentage }.reduce(0) { $0 + $1.amount }
    }
}

// MARK: - Owners

/// The four kinds of party an invoice can be addressed to.
public enum OwnerType: String, Codable, Sendable, CaseIterable {
    case customer, vendor, employee, job
}

/// A customer — someone you invoice (GnuCash `gncCustomer`).
public final class Customer: Identifiable, @unchecked Sendable {
    public let guid: GncGUID
    /// Human-facing number ("000001").
    public var id: String
    public var name: String
    public var address: BusinessAddress
    public var notes: String
    public var active: Bool
    public var currency: Commodity
    public var terms: BillTerm?
    public var taxTable: TaxTable?
    /// Whether the customer's tax table overrides each entry's.
    public var taxTableOverride: Bool
    /// Whether prices are entered tax-inclusive for this customer.
    public var taxIncluded: Bool
    public var discountPercent: Decimal
    public var creditLimit: Decimal

    public init(guid: GncGUID = .random(), id: String, name: String,
                address: BusinessAddress = BusinessAddress(), notes: String = "",
                active: Bool = true, currency: Commodity, terms: BillTerm? = nil,
                taxTable: TaxTable? = nil, taxTableOverride: Bool = false,
                taxIncluded: Bool = false, discountPercent: Decimal = 0,
                creditLimit: Decimal = 0) {
        self.guid = guid; self.id = id; self.name = name; self.address = address
        self.notes = notes; self.active = active; self.currency = currency
        self.terms = terms; self.taxTable = taxTable
        self.taxTableOverride = taxTableOverride; self.taxIncluded = taxIncluded
        self.discountPercent = discountPercent; self.creditLimit = creditLimit
    }
}

/// A vendor — someone who bills you (GnuCash `gncVendor`).
public final class Vendor: Identifiable, @unchecked Sendable {
    public let guid: GncGUID
    public var id: String
    public var name: String
    public var address: BusinessAddress
    public var notes: String
    public var active: Bool
    public var currency: Commodity
    public var terms: BillTerm?
    public var taxTable: TaxTable?
    public var taxTableOverride: Bool
    public var taxIncluded: Bool

    public init(guid: GncGUID = .random(), id: String, name: String,
                address: BusinessAddress = BusinessAddress(), notes: String = "",
                active: Bool = true, currency: Commodity, terms: BillTerm? = nil,
                taxTable: TaxTable? = nil, taxTableOverride: Bool = false,
                taxIncluded: Bool = false) {
        self.guid = guid; self.id = id; self.name = name; self.address = address
        self.notes = notes; self.active = active; self.currency = currency
        self.terms = terms; self.taxTable = taxTable
        self.taxTableOverride = taxTableOverride; self.taxIncluded = taxIncluded
    }
}

/// An employee — who submits expense vouchers (GnuCash `gncEmployee`).
public final class Employee: Identifiable, @unchecked Sendable {
    public let guid: GncGUID
    public var id: String
    public var username: String
    public var address: BusinessAddress
    public var notes: String
    public var active: Bool
    public var currency: Commodity
    public var hourlyRate: Decimal
    /// The credit-card / liability account expenses are charged to.
    public var creditAccount: Account?

    public init(guid: GncGUID = .random(), id: String, username: String,
                address: BusinessAddress = BusinessAddress(), notes: String = "",
                active: Bool = true, currency: Commodity, hourlyRate: Decimal = 0,
                creditAccount: Account? = nil) {
        self.guid = guid; self.id = id; self.username = username; self.address = address
        self.notes = notes; self.active = active; self.currency = currency
        self.hourlyRate = hourlyRate; self.creditAccount = creditAccount
    }
}

/// A job groups invoices under a customer or a vendor (GnuCash `gncJob`).
public final class Job: Identifiable, @unchecked Sendable {
    public let guid: GncGUID
    public var id: String
    public var name: String
    public var reference: String
    public var active: Bool
    /// The customer or vendor the job belongs to.
    public var owner: BusinessOwner

    public init(guid: GncGUID = .random(), id: String, name: String,
                reference: String = "", active: Bool = true, owner: BusinessOwner) {
        self.guid = guid; self.id = id; self.name = name
        self.reference = reference; self.active = active; self.owner = owner
    }
}

/// A party an invoice is addressed to: a customer, a vendor, an employee, or a
/// job (which resolves to its own customer or vendor).
public enum BusinessOwner: @unchecked Sendable {
    case customer(Customer)
    case vendor(Vendor)
    case employee(Employee)
    case job(Job)

    public var type: OwnerType {
        switch self {
        case .customer: .customer
        case .vendor: .vendor
        case .employee: .employee
        case .job: .job
        }
    }

    public var displayName: String {
        switch self {
        case .customer(let c): c.name
        case .vendor(let v): v.name
        case .employee(let e): e.username
        case .job(let j): j.name
        }
    }

    public var currency: Commodity {
        switch self {
        case .customer(let c): c.currency
        case .vendor(let v): v.currency
        case .employee(let e): e.currency
        case .job(let j): j.owner.currency
        }
    }

    public var terms: BillTerm? {
        switch self {
        case .customer(let c): c.terms
        case .vendor(let v): v.terms
        case .employee: nil
        case .job(let j): j.owner.terms
        }
    }

    /// The party's own tax table, if any (jobs inherit their owner's).
    public var taxTable: TaxTable? {
        switch self {
        case .customer(let c): c.taxTableOverride ? c.taxTable : nil
        case .vendor(let v): v.taxTableOverride ? v.taxTable : nil
        case .employee: nil
        case .job(let j): j.owner.taxTable
        }
    }

    /// Whether money is *owed to us* (receivable) or *by us* (payable).
    public var postingAccountType: AccountType {
        switch self {
        case .customer, .job: .receivable   // a job resolves to receivable/payable
        case .vendor, .employee: .payable
        }
    }

    /// The stable identity of the underlying party.
    public var guid: GncGUID {
        switch self {
        case .customer(let c): c.guid
        case .vendor(let v): v.guid
        case .employee(let e): e.guid
        case .job(let j): j.guid
        }
    }
}

// MARK: - Invoices and entries

/// What an invoice document is: a customer invoice (A/R), a vendor bill (A/P),
/// or an employee expense voucher (A/P).
public enum InvoiceKind: String, Codable, Sendable, CaseIterable {
    case invoice   // to a customer
    case bill      // from a vendor
    case voucher   // from an employee

    /// The account nature the document posts to.
    public var postingAccountType: AccountType {
        self == .invoice ? .receivable : .payable
    }
}

/// How a line discount is expressed.
public enum DiscountType: String, Codable, Sendable, CaseIterable {
    case percentage, value
}

/// One line of an invoice/bill (GnuCash `gncEntry`). The public computed
/// properties reproduce GnuCash's entry arithmetic for the common case: a
/// pre-tax discount and tax-exclusive pricing.
public final class InvoiceEntry: Identifiable, @unchecked Sendable {
    public let guid: GncGUID
    public var date: Date
    public var entryDescription: String
    public var action: String
    /// The income (invoice) or expense (bill) account this line books to.
    public var account: Account?
    public var quantity: Decimal
    public var price: Decimal
    public var discount: Decimal
    public var discountType: DiscountType
    public var taxable: Bool
    public var taxIncluded: Bool
    public var taxTable: TaxTable?

    public init(guid: GncGUID = .random(), date: Date = Date(),
                entryDescription: String = "", action: String = "",
                account: Account? = nil, quantity: Decimal = 1, price: Decimal = 0,
                discount: Decimal = 0, discountType: DiscountType = .percentage,
                taxable: Bool = false, taxIncluded: Bool = false,
                taxTable: TaxTable? = nil) {
        self.guid = guid; self.date = date; self.entryDescription = entryDescription
        self.action = action; self.account = account; self.quantity = quantity
        self.price = price; self.discount = discount; self.discountType = discountType
        self.taxable = taxable; self.taxIncluded = taxIncluded; self.taxTable = taxTable
    }

    /// Line amount before discount and tax (quantity × price).
    public var gross: Decimal { quantity * price }

    /// The discount amount deducted from `gross`.
    public var discountAmount: Decimal {
        switch discountType {
        case .percentage: gross * discount / 100
        case .value: discount
        }
    }

    /// The line subtotal: gross less discount (the pre-tax, taxable base).
    public var subtotal: Decimal { gross - discountAmount }

    /// Tax on this line, per `taxTable`, when `taxable`. Percentage entries take
    /// a share of the subtotal; value entries add a flat amount.
    public var tax: Decimal {
        guard taxable, let table = taxTable else { return 0 }
        return table.entries.reduce(Decimal(0)) { running, entry in
            switch entry.kind {
            case .percentage: running + subtotal * entry.amount / 100
            case .value: running + entry.amount
            }
        }
    }

    /// Subtotal plus tax.
    public var total: Decimal { subtotal + tax }
}

/// An invoice, bill, or expense voucher (GnuCash `gncInvoice`). Its entries are
/// summed here; posting it to A/R/A/P lives in `BusinessPosting.swift`.
public final class Invoice: Identifiable, @unchecked Sendable {
    public let guid: GncGUID
    public var id: String
    public var kind: InvoiceKind
    public var owner: BusinessOwner
    public var dateOpened: Date
    public var datePosted: Date?
    public var dueDate: Date?
    public var terms: BillTerm?
    public var billingID: String
    public var notes: String
    public var currency: Commodity
    public var entries: [InvoiceEntry]
    /// The A/R or A/P account this invoice was posted to (once posted).
    public var postedAccount: Account?
    /// The transaction created when the invoice was posted.
    public var postedTransaction: Transaction?
    /// The lot the posting and its payments belong to.
    public var postedLot: Lot?
    public var active: Bool

    public init(guid: GncGUID = .random(), id: String, kind: InvoiceKind,
                owner: BusinessOwner, dateOpened: Date = Date(),
                datePosted: Date? = nil, dueDate: Date? = nil, terms: BillTerm? = nil,
                billingID: String = "", notes: String = "", currency: Commodity,
                entries: [InvoiceEntry] = [], active: Bool = true) {
        self.guid = guid; self.id = id; self.kind = kind; self.owner = owner
        self.dateOpened = dateOpened; self.datePosted = datePosted; self.dueDate = dueDate
        self.terms = terms; self.billingID = billingID; self.notes = notes
        self.currency = currency; self.entries = entries; self.active = active
    }

    public var isPosted: Bool { datePosted != nil }

    /// Sum of line subtotals, rounded to the invoice currency.
    public var subtotal: Decimal {
        currency.round(entries.reduce(Decimal(0)) { $0 + $1.subtotal })
    }

    /// Total tax, rounded to the invoice currency.
    public var taxTotal: Decimal {
        currency.round(entries.reduce(Decimal(0)) { $0 + $1.tax })
    }

    /// The amount owed: subtotal plus tax.
    public var total: Decimal { currency.round(subtotal + taxTotal) }

    /// Line subtotals grouped by income/expense account, for posting.
    public func subtotalsByAccount() -> [(account: Account, amount: Decimal)] {
        group(entries.compactMap { entry in entry.account.map { ($0, entry.subtotal) } })
    }

    /// Tax amounts grouped by the tax-collecting account, for posting.
    public func taxByAccount() -> [(account: Account, amount: Decimal)] {
        var pairs: [(Account, Decimal)] = []
        for entry in entries where entry.taxable {
            guard let table = entry.taxTable else { continue }
            for line in table.entries {
                let amount = line.kind == .percentage
                    ? entry.subtotal * line.amount / 100 : line.amount
                pairs.append((line.account, amount))
            }
        }
        return group(pairs)
    }

    private func group(_ pairs: [(Account, Decimal)]) -> [(account: Account, amount: Decimal)] {
        var order: [ObjectIdentifier] = []
        var totals: [ObjectIdentifier: (Account, Decimal)] = [:]
        for (account, amount) in pairs {
            let key = ObjectIdentifier(account)
            if let existing = totals[key] {
                totals[key] = (existing.0, existing.1 + amount)
            } else {
                totals[key] = (account, amount); order.append(key)
            }
        }
        return order.map { (totals[$0]!.0, currency.round(totals[$0]!.1)) }
    }
}
