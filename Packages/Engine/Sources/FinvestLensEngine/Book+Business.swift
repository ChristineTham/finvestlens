//
//  Book+Business.swift
//  FinvestLens — Engine
//
//  Registering and looking up the business object graph on a ``Book``
//  (`FR-BUS-*`).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public extension Book {

    // MARK: Registration

    @discardableResult
    func addCustomer(_ customer: Customer) -> Customer {
        customers.append(customer); registerCommodity(customer.currency); return customer
    }

    @discardableResult
    func addVendor(_ vendor: Vendor) -> Vendor {
        vendors.append(vendor); registerCommodity(vendor.currency); return vendor
    }

    @discardableResult
    func addEmployee(_ employee: Employee) -> Employee {
        employees.append(employee); registerCommodity(employee.currency); return employee
    }

    @discardableResult
    func addJob(_ job: Job) -> Job { jobs.append(job); return job }

    @discardableResult
    func addInvoice(_ invoice: Invoice) -> Invoice {
        invoices.append(invoice); registerCommodity(invoice.currency); return invoice
    }

    @discardableResult
    func addBillTerm(_ term: BillTerm) -> BillTerm { billTerms.append(term); return term }

    @discardableResult
    func addTaxTable(_ table: TaxTable) -> TaxTable { taxTables.append(table); return table }

    @discardableResult
    func addLot(_ lot: Lot) -> Lot { lots.append(lot); return lot }

    func removeInvoice(_ invoice: Invoice) {
        invoices.removeAll { $0 === invoice }
    }

    // MARK: Lookup

    func customer(with guid: GncGUID) -> Customer? { customers.first { $0.guid == guid } }
    func vendor(with guid: GncGUID) -> Vendor? { vendors.first { $0.guid == guid } }
    func employee(with guid: GncGUID) -> Employee? { employees.first { $0.guid == guid } }
    func job(with guid: GncGUID) -> Job? { jobs.first { $0.guid == guid } }
    func invoice(with guid: GncGUID) -> Invoice? { invoices.first { $0.guid == guid } }
    func taxTable(with guid: GncGUID) -> TaxTable? { taxTables.first { $0.guid == guid } }
    func billTerm(with guid: GncGUID) -> BillTerm? { billTerms.first { $0.guid == guid } }
    func lot(with guid: GncGUID) -> Lot? { lots.first { $0.guid == guid } }

    /// The lots that live in `account` (its A/R / A/P lots).
    func lots(in account: Account) -> [Lot] {
        lots.filter { $0.account === account }
    }

    /// Invoices addressed to a given party (by owner guid), posted or not.
    func invoices(forOwner ownerGuid: GncGUID) -> [Invoice] {
        invoices.filter { $0.owner.guid == ownerGuid }
    }

    // MARK: Default receivable / payable accounts

    /// The first non-placeholder A/R account, the default an invoice posts to.
    var defaultReceivable: Account? {
        accounts.first { $0.type == .receivable && !$0.isPlaceholder }
    }

    /// The first non-placeholder A/P account, the default a bill posts to.
    var defaultPayable: Account? {
        accounts.first { $0.type == .payable && !$0.isPlaceholder }
    }
}
