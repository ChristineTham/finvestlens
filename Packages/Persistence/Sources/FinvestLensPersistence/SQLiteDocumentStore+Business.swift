//
//  SQLiteDocumentStore+Business.swift
//  FinvestLens — Persistence
//
//  Snapshotting the business object graph (`FR-BUS-*`) to/from SQLite. GUIDs
//  carry every cross-reference so the graph rebuilds by identity on read.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import FinvestLensEngine

extension SQLiteDocumentStore {

    // MARK: - Write

    static func writeBusiness(_ book: Book, into db: Database) throws {
        for term in book.billTerms {
            try db.execute(sql: """
                INSERT INTO billterm (guid, name, termDescription, kind, dueDays,
                    discountDays, cutoff, discountPercent, active) VALUES (?,?,?,?,?,?,?,?,?)
                """, arguments: [term.guid.hexString, term.name, term.termDescription,
                    term.kind.rawValue, term.dueDays, term.discountDays, term.cutoff,
                    Serialize.decimal(term.discountPercent), term.active])
        }
        for table in book.taxTables {
            try db.execute(sql: "INSERT INTO taxtable (guid, name, active) VALUES (?,?,?)",
                           arguments: [table.guid.hexString, table.name, table.active])
            for (position, entry) in table.entries.enumerated() {
                try db.execute(sql: """
                    INSERT INTO taxtable_entry (taxtableGuid, accountGuid, kind, amount, position)
                    VALUES (?,?,?,?,?)
                    """, arguments: [table.guid.hexString, entry.account.guid.hexString,
                        entry.kind.rawValue, Serialize.decimal(entry.amount), position])
            }
        }
        for customer in book.customers {
            try db.execute(sql: """
                INSERT INTO customer (guid, id, name, address, notes, active,
                    currencyNamespace, currencyMnemonic, termsGuid, taxTableGuid,
                    taxTableOverride, taxIncluded, discountPercent, creditLimit)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [customer.guid.hexString, customer.id, customer.name,
                    encodeAddress(customer.address), customer.notes, customer.active,
                    Serialize.namespace(customer.currency.namespace), customer.currency.mnemonic,
                    customer.terms?.guid.hexString, customer.taxTable?.guid.hexString,
                    customer.taxTableOverride, customer.taxIncluded,
                    Serialize.decimal(customer.discountPercent),
                    Serialize.decimal(customer.creditLimit)])
        }
        for vendor in book.vendors {
            try db.execute(sql: """
                INSERT INTO vendor (guid, id, name, address, notes, active,
                    currencyNamespace, currencyMnemonic, termsGuid, taxTableGuid,
                    taxTableOverride, taxIncluded, discountPercent, creditLimit)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [vendor.guid.hexString, vendor.id, vendor.name,
                    encodeAddress(vendor.address), vendor.notes, vendor.active,
                    Serialize.namespace(vendor.currency.namespace), vendor.currency.mnemonic,
                    vendor.terms?.guid.hexString, vendor.taxTable?.guid.hexString,
                    vendor.taxTableOverride, vendor.taxIncluded, "0", "0"])
        }
        for employee in book.employees {
            try db.execute(sql: """
                INSERT INTO employee (guid, id, username, address, notes, active,
                    currencyNamespace, currencyMnemonic, hourlyRate, creditAccountGuid)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, arguments: [employee.guid.hexString, employee.id, employee.username,
                    encodeAddress(employee.address), employee.notes, employee.active,
                    Serialize.namespace(employee.currency.namespace), employee.currency.mnemonic,
                    Serialize.decimal(employee.hourlyRate), employee.creditAccount?.guid.hexString])
        }
        for job in book.jobs {
            try db.execute(sql: """
                INSERT INTO job (guid, id, name, reference, active, ownerType, ownerGuid)
                VALUES (?,?,?,?,?,?,?)
                """, arguments: [job.guid.hexString, job.id, job.name, job.reference,
                    job.active, job.owner.type.rawValue, job.owner.guid.hexString])
        }
        for lot in book.lots {
            try db.execute(sql: """
                INSERT INTO lot (guid, accountGuid, title, notes, isClosed, kvp)
                VALUES (?,?,?,?,?,?)
                """, arguments: [lot.guid.hexString, lot.account?.guid.hexString, lot.title,
                    lot.notes, lot.isClosed, Serialize.kvp(lot.kvp)])
            for (position, split) in lot.splits.enumerated() {
                try db.execute(sql: """
                    INSERT INTO lot_split (lotGuid, splitGuid, position) VALUES (?,?,?)
                    """, arguments: [lot.guid.hexString, split.guid.hexString, position])
            }
        }
        for invoice in book.invoices {
            try db.execute(sql: """
                INSERT INTO invoice (guid, id, kind, ownerType, ownerGuid, dateOpened,
                    datePosted, dueDate, termsGuid, billingID, notes, currencyNamespace,
                    currencyMnemonic, postedAccountGuid, postedTxnGuid, postedLotGuid, active)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [invoice.guid.hexString, invoice.id, invoice.kind.rawValue,
                    invoice.owner.type.rawValue, invoice.owner.guid.hexString, invoice.dateOpened,
                    invoice.datePosted, invoice.dueDate, invoice.terms?.guid.hexString,
                    invoice.billingID, invoice.notes,
                    Serialize.namespace(invoice.currency.namespace), invoice.currency.mnemonic,
                    invoice.postedAccount?.guid.hexString, invoice.postedTransaction?.guid.hexString,
                    invoice.postedLot?.guid.hexString, invoice.active])
            for (position, entry) in invoice.entries.enumerated() {
                try db.execute(sql: """
                    INSERT INTO invoice_entry (guid, invoiceGuid, date, entryDescription,
                        action, accountGuid, quantity, price, discount, discountType,
                        discountHow, taxable, taxIncluded, taxTableGuid, position)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [entry.guid.hexString, invoice.guid.hexString, entry.date,
                        entry.entryDescription, entry.action, entry.account?.guid.hexString,
                        Serialize.decimal(entry.quantity), Serialize.decimal(entry.price),
                        Serialize.decimal(entry.discount), entry.discountType.rawValue,
                        entry.discountHow.rawValue,
                        entry.taxable, entry.taxIncluded, entry.taxTable?.guid.hexString, position])
            }
        }
    }

    // MARK: - Read

    static func readBusiness(into book: Book, db: Database,
                             accounts: [GncGUID: Account], splits: [GncGUID: Split],
                             commodity: (String, String) -> Commodity) throws {
        func acct(_ hex: String?) -> Account? { hex.flatMap { GncGUID(hex: $0) }.flatMap { accounts[$0] } }

        var termsByGUID: [GncGUID: BillTerm] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM billterm") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let term = BillTerm(guid: guid, name: row["name"], termDescription: row["termDescription"],
                kind: BillTerm.Kind(rawValue: row["kind"]) ?? .days, dueDays: row["dueDays"],
                discountDays: row["discountDays"], cutoff: row["cutoff"],
                discountPercent: Serialize.parseDecimal(row["discountPercent"]), active: row["active"])
            termsByGUID[guid] = term
            book.addBillTerm(term)
        }

        var tablesByGUID: [GncGUID: TaxTable] = [:]
        var entryRows: [String: [Row]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM taxtable_entry ORDER BY position") {
            entryRows[row["taxtableGuid"], default: []].append(row)
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM taxtable") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let entries: [TaxTableEntry] = (entryRows[row["guid"]] ?? []).compactMap { e in
                guard let account = acct(e["accountGuid"]) else { return nil }
                return TaxTableEntry(account: account,
                    kind: TaxTableEntry.Kind(rawValue: e["kind"]) ?? .percentage,
                    amount: Serialize.parseDecimal(e["amount"]))
            }
            let table = TaxTable(guid: guid, name: row["name"], entries: entries, active: row["active"])
            tablesByGUID[guid] = table
            book.addTaxTable(table)
        }
        func table(_ hex: String?) -> TaxTable? { hex.flatMap { GncGUID(hex: $0) }.flatMap { tablesByGUID[$0] } }
        func term(_ hex: String?) -> BillTerm? { hex.flatMap { GncGUID(hex: $0) }.flatMap { termsByGUID[$0] } }

        var customersByGUID: [GncGUID: Customer] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM customer") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let customer = Customer(guid: guid, id: row["id"], name: row["name"],
                address: decodeAddress(row["address"]), notes: row["notes"], active: row["active"],
                currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                terms: term(row["termsGuid"]), taxTable: table(row["taxTableGuid"]),
                taxTableOverride: row["taxTableOverride"], taxIncluded: row["taxIncluded"],
                discountPercent: Serialize.parseDecimal(row["discountPercent"]),
                creditLimit: Serialize.parseDecimal(row["creditLimit"]))
            customersByGUID[guid] = customer
            book.addCustomer(customer)
        }
        var vendorsByGUID: [GncGUID: Vendor] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM vendor") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let vendor = Vendor(guid: guid, id: row["id"], name: row["name"],
                address: decodeAddress(row["address"]), notes: row["notes"], active: row["active"],
                currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                terms: term(row["termsGuid"]), taxTable: table(row["taxTableGuid"]),
                taxTableOverride: row["taxTableOverride"], taxIncluded: row["taxIncluded"])
            vendorsByGUID[guid] = vendor
            book.addVendor(vendor)
        }
        var employeesByGUID: [GncGUID: Employee] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM employee") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let employee = Employee(guid: guid, id: row["id"], username: row["username"],
                address: decodeAddress(row["address"]), notes: row["notes"], active: row["active"],
                currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                hourlyRate: Serialize.parseDecimal(row["hourlyRate"]),
                creditAccount: acct(row["creditAccountGuid"]))
            employeesByGUID[guid] = employee
            book.addEmployee(employee)
        }
        // Jobs: resolve owner (customer or vendor).
        var jobsByGUID: [GncGUID: Job] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM job") {
            guard let guid = GncGUID(hex: row["guid"]),
                  let ownerGuid = GncGUID(hex: row["ownerGuid"]),
                  let owner = owner(type: row["ownerType"], guid: ownerGuid,
                                    customersByGUID, vendorsByGUID, employeesByGUID, [:])
            else { continue }
            let job = Job(guid: guid, id: row["id"], name: row["name"],
                          reference: row["reference"], active: row["active"], owner: owner)
            jobsByGUID[guid] = job
            book.addJob(job)
        }

        // Lots, with their split membership.
        var lotSplitRows: [String: [Row]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM lot_split ORDER BY position") {
            lotSplitRows[row["lotGuid"], default: []].append(row)
        }
        var lotsByGUID: [GncGUID: Lot] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM lot") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let lot = Lot(guid: guid, account: acct(row["accountGuid"]), title: row["title"],
                          notes: row["notes"], isClosed: row["isClosed"],
                          kvp: Serialize.parseKvp(row["kvp"]))
            for sr in lotSplitRows[row["guid"]] ?? [] {
                if let sg = GncGUID(hex: sr["splitGuid"]), let split = splits[sg] { lot.add(split) }
            }
            lotsByGUID[guid] = lot
            book.addLot(lot)
        }

        // Invoices and entries.
        var invEntryRows: [String: [Row]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM invoice_entry ORDER BY position") {
            invEntryRows[row["invoiceGuid"], default: []].append(row)
        }
        let txnsByGUID = Dictionary(book.transactions.map { ($0.guid, $0) }, uniquingKeysWith: { a, _ in a })
        for row in try Row.fetchAll(db, sql: "SELECT * FROM invoice") {
            guard let guid = GncGUID(hex: row["guid"]),
                  let ownerGuid = GncGUID(hex: row["ownerGuid"]),
                  let owner = owner(type: row["ownerType"], guid: ownerGuid,
                                    customersByGUID, vendorsByGUID, employeesByGUID, jobsByGUID)
            else { continue }
            let invoice = Invoice(guid: guid, id: row["id"],
                kind: InvoiceKind(rawValue: row["kind"]) ?? .invoice, owner: owner,
                dateOpened: row["dateOpened"], datePosted: row["datePosted"], dueDate: row["dueDate"],
                terms: term(row["termsGuid"]), billingID: row["billingID"], notes: row["notes"],
                currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                active: row["active"])
            invoice.entries = (invEntryRows[row["guid"]] ?? []).map { e in
                InvoiceEntry(guid: GncGUID(hex: e["guid"]) ?? .random(), date: e["date"],
                    entryDescription: e["entryDescription"], action: e["action"],
                    account: acct(e["accountGuid"]), quantity: Serialize.parseDecimal(e["quantity"]),
                    price: Serialize.parseDecimal(e["price"]),
                    discount: Serialize.parseDecimal(e["discount"]),
                    discountType: DiscountType(rawValue: e["discountType"]) ?? .percentage,
                    discountHow: DiscountHow(rawValue: e["discountHow"] ?? "pretax") ?? .pretax,
                    taxable: e["taxable"], taxIncluded: e["taxIncluded"], taxTable: table(e["taxTableGuid"]))
            }
            invoice.postedAccount = acct(row["postedAccountGuid"])
            invoice.postedTransaction = (row["postedTxnGuid"] as String?).flatMap { GncGUID(hex: $0) }
                .flatMap { txnsByGUID[$0] }
            invoice.postedLot = (row["postedLotGuid"] as String?).flatMap { GncGUID(hex: $0) }
                .flatMap { lotsByGUID[$0] }
            book.addInvoice(invoice)
        }
    }

    private static func owner(type: String, guid: GncGUID,
                              _ customers: [GncGUID: Customer], _ vendors: [GncGUID: Vendor],
                              _ employees: [GncGUID: Employee], _ jobs: [GncGUID: Job]) -> BusinessOwner? {
        switch OwnerType(rawValue: type) {
        case .customer: customers[guid].map { .customer($0) }
        case .vendor: vendors[guid].map { .vendor($0) }
        case .employee: employees[guid].map { .employee($0) }
        case .job: jobs[guid].map { .job($0) }
        case nil: nil
        }
    }

    // MARK: - Address (JSON)

    private static func encodeAddress(_ address: BusinessAddress) -> String? {
        (try? JSONEncoder().encode(address)).flatMap { String(data: $0, encoding: .utf8) }
    }
    private static func decodeAddress(_ text: String?) -> BusinessAddress {
        guard let text else { return BusinessAddress() }
        guard let data = text.data(using: .utf8),
              let address = try? JSONDecoder().decode(BusinessAddress.self, from: data)
        else {
            persistenceLog.warning("Unparseable business address discarded")
            return BusinessAddress()
        }
        return address
    }
}
