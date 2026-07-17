//
//  BusinessPosting.swift
//  FinvestLens — Engine
//
//  Posting an invoice/bill to A/R/A/P (GnuCash `gncInvoicePostToAccount`): the
//  document becomes a balanced transaction — the total to the receivable or
//  payable account in a lot, the line subtotals to their income/expense
//  accounts, and the tax to its collecting accounts. The lot is what later
//  payments settle against.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public extension Book {

    /// Whether posting the transaction records money *owed to us* (an invoice)
    /// or *owed by us* (a bill or voucher).
    private static func isReceivable(_ kind: InvoiceKind) -> Bool { kind == .invoice }

    /// GnuCash's `GncOwnerType` integer for a party, stored on business lots.
    static func gncOwnerType(_ owner: BusinessOwner) -> Int64 {
        switch owner.type {
        case .customer: 2   // GNC_OWNER_CUSTOMER
        case .job: 3        // GNC_OWNER_JOB
        case .vendor: 4     // GNC_OWNER_VENDOR
        case .employee: 5   // GNC_OWNER_EMPLOYEE
        }
    }

    /// Posts `invoice` to `account` (an A/R for an invoice, A/P for a bill or
    /// voucher), creating the balanced transaction and its settlement lot, and
    /// returns that transaction. Throws if already posted, the account's nature
    /// is wrong, or a line has no account.
    @discardableResult
    func postInvoice(_ invoice: Invoice, to account: Account, postDate: Date,
                     dueDate: Date? = nil, calendar: Calendar = .current) throws -> Transaction {
        guard !invoice.isPosted else { throw BusinessError.alreadyPosted }
        let receivable = Self.isReceivable(invoice.kind)
        let wantType: AccountType = receivable ? .receivable : .payable
        guard account.type == wantType else { throw BusinessError.wrongPostingAccount }
        guard invoice.entries.allSatisfy({ $0.account != nil }) else {
            throw BusinessError.entryMissingAccount
        }

        let resolvedDue = dueDate
            ?? invoice.terms?.dueDate(postedOn: postDate, calendar: calendar)
            ?? invoice.owner.terms?.dueDate(postedOn: postDate, calendar: calendar)
            ?? postDate

        let txn = Transaction(currency: invoice.currency, datePosted: postDate,
                              description: invoice.owner.displayName)
        txn.number = invoice.id
        // GnuCash marks an invoice posting so its business reports recognise it
        // and the register keeps it read-only until unposted. The `gncInvoice`
        // slot on the transaction is what the aging and owner reports read to
        // attribute the posting to its invoice — and thence its owner — via
        // `gncInvoiceGetInvoiceFromTxn` (GnuCash sets it in `gncInvoiceAttachTo
        // Txn`). Without it the reports find the account but "no suitable
        // transactions". `trans-date-due` carries the due date the aging report
        // buckets by (GnuCash's `xaccTransSetDateDue`).
        txn.kvp["trans-txn-type"] = .string("I")
        txn.kvp["trans-read-only"] = .string("Generated from an invoice. Try unposting the invoice.")
        txn.kvp["gncInvoice"] = .frame(KvpFrame(["invoice-guid": .guid(invoice.guid)]))
        txn.kvp["trans-date-due"] = .date(resolvedDue)

        let total = invoice.total
        // The receivable/payable leg: +total on an A/R (asset up), −total on an
        // A/P (liability up). Everything else is the mirror.
        let arValue = receivable ? total : -total
        let arSplit = Split(account: account, value: arValue, memo: invoice.id)
        arSplit.action = receivable ? "Invoice" : "Bill"
        arSplit.reconcileDate = resolvedDue        // due date rides on the A/R split
        txn.addSplit(arSplit)

        for (incomeAccount, subtotal) in invoice.subtotalsByAccount() {
            txn.addSplit(account: incomeAccount, value: receivable ? -subtotal : subtotal,
                         memo: invoice.id)
        }
        for (taxAccount, tax) in invoice.taxByAccount() where tax != 0 {
            txn.addSplit(account: taxAccount, value: receivable ? -tax : tax, memo: invoice.id)
        }

        addTransaction(txn)

        // The lot the posting and its payments settle in. GnuCash's aging and
        // owner reports find the invoice and its owner through these lot slots.
        let lot = Lot(account: account, title: invoice.id)
        lot.kvp["gncInvoice"] = .frame(KvpFrame(["invoice-guid": .guid(invoice.guid)]))
        lot.kvp["gncOwner"] = .frame(KvpFrame([
            "owner-type": .int64(Self.gncOwnerType(invoice.owner)),
            "owner-guid": .guid(invoice.owner.guid)]))
        lot.add(arSplit)
        addLot(lot)

        invoice.datePosted = postDate
        invoice.dueDate = resolvedDue
        invoice.postedAccount = account
        invoice.postedTransaction = txn
        invoice.postedLot = lot
        return txn
    }

    /// Reverses a posting: removes the transaction and empties the lot, so the
    /// invoice can be edited and re-posted (GnuCash "Unpost").
    func unpostInvoice(_ invoice: Invoice) {
        if let txn = invoice.postedTransaction { removeTransaction(txn) }
        if let lot = invoice.postedLot { lots.removeAll { $0 === lot } }
        invoice.datePosted = nil
        invoice.dueDate = nil
        invoice.postedAccount = nil
        invoice.postedTransaction = nil
        invoice.postedLot = nil
    }

    /// The amount still outstanding on a posted invoice (0 if unposted or paid).
    /// Always non-negative: it is the magnitude of the lot balance.
    func outstanding(_ invoice: Invoice) -> Decimal {
        guard let lot = invoice.postedLot else { return 0 }
        let balance = lot.balance
        return balance < 0 ? -balance : balance
    }
}

/// Errors from the business posting/payment layer.
public enum BusinessError: Error, Equatable, Sendable {
    case alreadyPosted
    case notPosted
    case wrongPostingAccount
    case entryMissingAccount
    case noOpenLots
}
