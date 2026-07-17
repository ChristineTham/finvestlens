//
//  GnuCashXMLExporter+Business.swift
//  FinvestLens — Interchange
//
//  Writing the business object graph (`FR-EXP`, `FR-BUS-*`) in GnuCash XML v2 —
//  billing terms, tax tables, customers/vendors/employees, jobs, invoices and
//  their entries. Lots and their split back-references are written by the core
//  exporter (`<act:lots>` / `<split:lot>`).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

extension GnuCashXMLExporter {

    static func businessCountData(_ book: Book) -> String {
        var out = ""
        func line(_ type: String, _ count: Int) {
            if count > 0 { out += "<gnc:count-data cd:type=\"\(type)\">\(count)</gnc:count-data>\n" }
        }
        line("gnc:GncBillTerm", book.billTerms.count)
        line("gnc:GncTaxTable", book.taxTables.count)
        line("gnc:GncCustomer", book.customers.count)
        line("gnc:GncVendor", book.vendors.count)
        line("gnc:GncEmployee", book.employees.count)
        line("gnc:GncJob", book.jobs.count)
        line("gnc:GncInvoice", book.invoices.count)
        line("gnc:GncEntry", book.invoices.reduce(0) { $0 + $1.entries.count })
        return out
    }

    static func businessBlocks(_ book: Book) -> String {
        var out = ""
        for term in book.billTerms { out += billTermBlock(term) }
        for table in book.taxTables { out += taxTableBlock(table) }
        for customer in book.customers { out += customerBlock(customer) }
        for vendor in book.vendors { out += vendorBlock(vendor) }
        for employee in book.employees { out += employeeBlock(employee) }
        for job in book.jobs { out += jobBlock(job) }
        for invoice in book.invoices {
            out += invoiceBlock(invoice)
            for entry in invoice.entries { out += entryBlock(entry, invoice: invoice) }
        }
        return out
    }

    // MARK: Billing terms

    private static func billTermBlock(_ term: BillTerm) -> String {
        var b = "<gnc:GncBillTerm version=\"2.0.0\">\n"
        b += "  <billterm:guid type=\"guid\">\(term.guid.hexString)</billterm:guid>\n"
        b += "  <billterm:name>\(escape(term.name))</billterm:name>\n"
        b += "  <billterm:desc>\(escape(term.termDescription))</billterm:desc>\n"
        b += "  <billterm:refcount>1</billterm:refcount>\n"
        b += "  <billterm:invisible>\(term.active ? 0 : 1)</billterm:invisible>\n"
        switch term.kind {
        case .days:
            b += "  <billterm:days>\n"
            b += "    <bt-days:due-days>\(term.dueDays)</bt-days:due-days>\n"
            b += "    <bt-days:disc-days>\(term.discountDays)</bt-days:disc-days>\n"
            b += "    <bt-days:discount>\(rational(term.discountPercent, fallbackFraction: 100))</bt-days:discount>\n"
            b += "  </billterm:days>\n"
        case .proximo:
            b += "  <billterm:prox>\n"
            b += "    <bt-prox:due-day>\(term.dueDays)</bt-prox:due-day>\n"
            b += "    <bt-prox:disc-day>\(term.discountDays)</bt-prox:disc-day>\n"
            b += "    <bt-prox:cutoff-day>\(term.cutoff)</bt-prox:cutoff-day>\n"
            b += "    <bt-prox:discount>\(rational(term.discountPercent, fallbackFraction: 100))</bt-prox:discount>\n"
            b += "  </billterm:prox>\n"
        }
        b += "</gnc:GncBillTerm>\n"
        return b
    }

    // MARK: Tax tables

    private static func taxTableBlock(_ table: TaxTable) -> String {
        var b = "<gnc:GncTaxTable version=\"2.0.0\">\n"
        b += "  <taxtable:guid type=\"guid\">\(table.guid.hexString)</taxtable:guid>\n"
        b += "  <taxtable:name>\(escape(table.name))</taxtable:name>\n"
        b += "  <taxtable:refcount>1</taxtable:refcount>\n"
        b += "  <taxtable:invisible>\(table.active ? 0 : 1)</taxtable:invisible>\n"
        b += "  <taxtable:entries>\n"
        for entry in table.entries {
            b += "    <gnc:GncTaxTableEntry>\n"
            b += "      <tte:acct type=\"guid\">\(entry.account.guid.hexString)</tte:acct>\n"
            b += "      <tte:type>\(entry.kind == .percentage ? "PERCENT" : "VALUE")</tte:type>\n"
            b += "      <tte:amount>\(rational(entry.amount, fallbackFraction: 100))</tte:amount>\n"
            b += "    </gnc:GncTaxTableEntry>\n"
        }
        b += "  </taxtable:entries>\n"
        b += "</gnc:GncTaxTable>\n"
        return b
    }

    // MARK: Parties

    private static func addressBlock(_ address: BusinessAddress, wrapper: String) -> String {
        var b = "  <\(wrapper)>\n"
        b += "    <addr:name>\(escape(address.name))</addr:name>\n"
        b += "    <addr:addr1>\(escape(address.line1))</addr:addr1>\n"
        b += "    <addr:addr2>\(escape(address.line2))</addr:addr2>\n"
        b += "    <addr:addr3>\(escape(address.line3))</addr:addr3>\n"
        b += "    <addr:addr4>\(escape(address.line4))</addr:addr4>\n"
        if !address.phone.isEmpty { b += "    <addr:phone>\(escape(address.phone))</addr:phone>\n" }
        if !address.fax.isEmpty { b += "    <addr:fax>\(escape(address.fax))</addr:fax>\n" }
        if !address.email.isEmpty { b += "    <addr:email>\(escape(address.email))</addr:email>\n" }
        b += "  </\(wrapper)>\n"
        return b
    }

    private static func currencyBlock(_ currency: Commodity, wrapper: String) -> String {
        var b = "  <\(wrapper)>\n"
        b += "    <cmdty:space>\(escape(namespace(currency.namespace)))</cmdty:space>\n"
        b += "    <cmdty:id>\(escape(currency.mnemonic))</cmdty:id>\n"
        b += "  </\(wrapper)>\n"
        return b
    }

    private static func customerBlock(_ c: Customer) -> String {
        var b = "<gnc:GncCustomer version=\"2.0.0\">\n"
        b += "  <cust:guid type=\"guid\">\(c.guid.hexString)</cust:guid>\n"
        b += "  <cust:name>\(escape(c.name))</cust:name>\n"
        b += "  <cust:id>\(escape(c.id))</cust:id>\n"
        b += addressBlock(c.address, wrapper: "cust:addr")
        b += addressBlock(c.address, wrapper: "cust:shipaddr")
        if !c.notes.isEmpty { b += "  <cust:notes>\(escape(c.notes))</cust:notes>\n" }
        b += "  <cust:taxincluded>\(c.taxIncluded ? "YES" : "USEGLOBAL")</cust:taxincluded>\n"
        b += "  <cust:active>\(c.active ? 1 : 0)</cust:active>\n"
        b += "  <cust:discount>\(rational(c.discountPercent, fallbackFraction: 100))</cust:discount>\n"
        b += "  <cust:credit>\(rational(c.creditLimit, fallbackFraction: 100))</cust:credit>\n"
        b += currencyBlock(c.currency, wrapper: "cust:currency")
        b += "  <cust:use-tt>\(c.taxTableOverride ? 1 : 0)</cust:use-tt>\n"
        if let terms = c.terms { b += "  <cust:terms type=\"guid\">\(terms.guid.hexString)</cust:terms>\n" }
        if let table = c.taxTable { b += "  <cust:taxtable type=\"guid\">\(table.guid.hexString)</cust:taxtable>\n" }
        b += "</gnc:GncCustomer>\n"
        return b
    }

    private static func vendorBlock(_ v: Vendor) -> String {
        var b = "<gnc:GncVendor version=\"2.0.0\">\n"
        b += "  <vendor:guid type=\"guid\">\(v.guid.hexString)</vendor:guid>\n"
        b += "  <vendor:name>\(escape(v.name))</vendor:name>\n"
        b += "  <vendor:id>\(escape(v.id))</vendor:id>\n"
        b += addressBlock(v.address, wrapper: "vendor:addr")
        if !v.notes.isEmpty { b += "  <vendor:notes>\(escape(v.notes))</vendor:notes>\n" }
        b += "  <vendor:taxincluded>\(v.taxIncluded ? "YES" : "USEGLOBAL")</vendor:taxincluded>\n"
        b += "  <vendor:active>\(v.active ? 1 : 0)</vendor:active>\n"
        b += currencyBlock(v.currency, wrapper: "vendor:currency")
        b += "  <vendor:use-tt>\(v.taxTableOverride ? 1 : 0)</vendor:use-tt>\n"
        if let terms = v.terms { b += "  <vendor:terms type=\"guid\">\(terms.guid.hexString)</vendor:terms>\n" }
        if let table = v.taxTable { b += "  <vendor:taxtable type=\"guid\">\(table.guid.hexString)</vendor:taxtable>\n" }
        b += "</gnc:GncVendor>\n"
        return b
    }

    private static func employeeBlock(_ e: Employee) -> String {
        var b = "<gnc:GncEmployee version=\"2.0.0\">\n"
        b += "  <employee:guid type=\"guid\">\(e.guid.hexString)</employee:guid>\n"
        b += "  <employee:username>\(escape(e.username))</employee:username>\n"
        b += "  <employee:id>\(escape(e.id))</employee:id>\n"
        b += addressBlock(e.address, wrapper: "employee:addr")
        b += "  <employee:active>\(e.active ? 1 : 0)</employee:active>\n"
        b += "  <employee:rate>\(rational(e.hourlyRate, fallbackFraction: 100))</employee:rate>\n"
        b += currencyBlock(e.currency, wrapper: "employee:currency")
        if let account = e.creditAccount {
            b += "  <employee:ccard type=\"guid\">\(account.guid.hexString)</employee:ccard>\n"
        }
        b += "</gnc:GncEmployee>\n"
        return b
    }

    private static func ownerBlock(_ owner: BusinessOwner, wrapper: String) -> String {
        let type: String
        switch owner.type {
        case .customer: type = "gncCustomer"
        case .vendor: type = "gncVendor"
        case .employee: type = "gncEmployee"
        case .job: type = "gncJob"
        }
        var b = "  <\(wrapper)>\n"
        b += "    <owner:type>\(type)</owner:type>\n"
        b += "    <owner:id type=\"guid\">\(owner.guid.hexString)</owner:id>\n"
        b += "  </\(wrapper)>\n"
        return b
    }

    private static func jobBlock(_ j: Job) -> String {
        var b = "<gnc:GncJob version=\"2.0.0\">\n"
        b += "  <job:guid type=\"guid\">\(j.guid.hexString)</job:guid>\n"
        b += "  <job:id>\(escape(j.id))</job:id>\n"
        b += "  <job:name>\(escape(j.name))</job:name>\n"
        b += "  <job:reference>\(escape(j.reference))</job:reference>\n"
        b += ownerBlock(j.owner, wrapper: "job:owner")
        b += "  <job:active>\(j.active ? 1 : 0)</job:active>\n"
        b += "</gnc:GncJob>\n"
        return b
    }

    // MARK: Invoices and entries

    private static func invoiceBlock(_ i: Invoice) -> String {
        var b = "<gnc:GncInvoice version=\"2.0.0\">\n"
        b += "  <invoice:guid type=\"guid\">\(i.guid.hexString)</invoice:guid>\n"
        b += "  <invoice:id>\(escape(i.id))</invoice:id>\n"
        b += ownerBlock(i.owner, wrapper: "invoice:owner")
        b += "  <invoice:opened><ts:date>\(GnuCashDate.format(i.dateOpened))</ts:date></invoice:opened>\n"
        if let posted = i.datePosted {
            b += "  <invoice:posted><ts:date>\(GnuCashDate.format(posted))</ts:date></invoice:posted>\n"
        }
        if let terms = i.terms { b += "  <invoice:terms type=\"guid\">\(terms.guid.hexString)</invoice:terms>\n" }
        if !i.billingID.isEmpty { b += "  <invoice:billing_id>\(escape(i.billingID))</invoice:billing_id>\n" }
        if !i.notes.isEmpty { b += "  <invoice:notes>\(escape(i.notes))</invoice:notes>\n" }
        b += "  <invoice:active>\(i.active ? 1 : 0)</invoice:active>\n"
        b += currencyBlock(i.currency, wrapper: "invoice:currency")
        if let account = i.postedAccount { b += "  <invoice:postacc type=\"guid\">\(account.guid.hexString)</invoice:postacc>\n" }
        if let txn = i.postedTransaction { b += "  <invoice:posttxn type=\"guid\">\(txn.guid.hexString)</invoice:posttxn>\n" }
        if let lot = i.postedLot { b += "  <invoice:postlot type=\"guid\">\(lot.guid.hexString)</invoice:postlot>\n" }
        b += "</gnc:GncInvoice>\n"
        return b
    }

    private static func entryBlock(_ e: InvoiceEntry, invoice: Invoice) -> String {
        // Customer invoices use the `i-` field family, vendor bills / employee
        // vouchers the `b-` family; the entry links back to its document.
        let bill = invoice.kind != .invoice
        let p = bill ? "b" : "i"
        var b = "<gnc:GncEntry version=\"2.0.0\">\n"
        b += "  <entry:guid type=\"guid\">\(e.guid.hexString)</entry:guid>\n"
        b += "  <entry:date><ts:date>\(GnuCashDate.format(e.date))</ts:date></entry:date>\n"
        b += "  <entry:entered><ts:date>\(GnuCashDate.format(e.date))</ts:date></entry:entered>\n"
        b += "  <entry:description>\(escape(e.entryDescription))</entry:description>\n"
        if !e.action.isEmpty { b += "  <entry:action>\(escape(e.action))</entry:action>\n" }
        b += "  <entry:qty>\(rational(e.quantity, fallbackFraction: 1000))</entry:qty>\n"
        if let account = e.account {
            b += "  <entry:\(p)-acct type=\"guid\">\(account.guid.hexString)</entry:\(p)-acct>\n"
        }
        b += "  <entry:\(p)-price>\(rational(e.price, fallbackFraction: 100))</entry:\(p)-price>\n"
        if !bill {
            b += "  <entry:i-discount>\(rational(e.discount, fallbackFraction: 100))</entry:i-discount>\n"
            b += "  <entry:i-disc-type>\(e.discountType == .percentage ? "PERCENT" : "VALUE")</entry:i-disc-type>\n"
            b += "  <entry:i-disc-how>\(e.discountHow.gnuCashName)</entry:i-disc-how>\n"
        }
        b += "  <entry:\(p)-taxable>\(e.taxable ? 1 : 0)</entry:\(p)-taxable>\n"
        b += "  <entry:\(p)-taxincluded>\(e.taxIncluded ? 1 : 0)</entry:\(p)-taxincluded>\n"
        if let table = e.taxTable {
            b += "  <entry:\(p)-taxtable type=\"guid\">\(table.guid.hexString)</entry:\(p)-taxtable>\n"
        }
        b += "  <entry:\(bill ? "bill" : "invoice") type=\"guid\">\(invoice.guid.hexString)</entry:\(bill ? "bill" : "invoice")>\n"
        b += "</gnc:GncEntry>\n"
        return b
    }
}
