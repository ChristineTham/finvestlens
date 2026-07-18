//
//  AppModel+Billable.swift
//  FinvestLens — FeatureUI
//
//  Billable time & mileage tracking (`FR-PLAN-14`). Entries are a KVP-backed
//  collection (like savings goals); gathering a customer's unbilled entries onto
//  an invoice reuses the business invoice machinery and marks them billed.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

@MainActor
extension AppModel {

    public func addBillableEntry(_ entry: BillableEntry) {
        billableEntries.append(entry)
        commitKvpCollections(named: "Add Billable Entry")
    }

    public func updateBillableEntry(_ entry: BillableEntry) {
        guard let index = billableEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        billableEntries[index] = entry
        commitKvpCollections(named: "Edit Billable Entry")
    }

    public func deleteBillableEntry(_ id: GncGUID) {
        billableEntries.removeAll { $0.id == id }
        commitKvpCollections(named: "Delete Billable Entry")
    }

    /// Unbilled entries assigned to a customer, oldest first.
    public func unbilledEntries(forCustomer customerID: GncGUID) -> [BillableEntry] {
        billableEntries
            .filter { !$0.billed && $0.customerID == customerID }
            .sorted { $0.date < $1.date }
    }

    /// Customers that have at least one unbilled entry, for the "bill now" list.
    public var customersWithUnbilledEntries: [Customer] {
        let ids = Set(billableEntries.filter { !$0.billed }.compactMap(\.customerID))
        return businessCustomers.filter { ids.contains($0.guid) }
    }

    /// Gathers a customer's unbilled entries onto a new invoice — one line per
    /// entry (quantity × rate), booking to each entry's income account or the
    /// `fallbackIncomeID` — then marks those entries billed. Returns the new
    /// invoice's id, or `nil` when there is nothing to bill or no usable account.
    @discardableResult
    public func createInvoiceFromUnbilled(
        customerID: GncGUID, invoiceNumber: String,
        fallbackIncomeID: GncGUID? = nil, dateOpened: Date = Date()
    ) -> GncGUID? {
        guard let book else { return nil }
        let entries = unbilledEntries(forCustomer: customerID)
        guard !entries.isEmpty else { return nil }

        var lines: [InvoiceLineInput] = []
        for entry in entries {
            guard let accountID = entry.incomeAccountID ?? fallbackIncomeID,
                  book.account(with: accountID) != nil else { return nil }
            let label = entry.detail.isEmpty
                ? (entry.kind == .time ? "Time" : "Mileage") : entry.detail
            lines.append(InvoiceLineInput(accountID: accountID, description: label,
                                          quantity: entry.quantity, price: entry.rate))
        }
        guard let invoiceID = createInvoice(id: invoiceNumber, kind: .invoice,
                                            ownerType: .customer, ownerID: customerID,
                                            dateOpened: dateOpened, lines: lines)
        else { return nil }

        // Mark them billed in one change (createInvoice already committed).
        let billedIDs = Set(entries.map(\.id))
        for index in billableEntries.indices where billedIDs.contains(billableEntries[index].id) {
            billableEntries[index].billed = true
        }
        commitKvpCollections(named: "Bill Time & Mileage")
        return invoiceID
    }
}
