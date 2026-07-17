//
//  BusinessPayment.swift
//  FinvestLens — Engine
//
//  Recording customer/vendor payments against A/R/A/P lots (GnuCash "Process
//  Payment"), and receivables/payables aging. A payment moves cash and settles
//  the owner's open invoices oldest-first, adding its settlement splits to the
//  same lots the postings opened; any surplus opens a pre-payment lot.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public extension Book {

    /// Records a payment of `amount` from/into `bankAccount` against `owner`'s
    /// open invoices in `postingAccount` (A/R for a customer, A/P for a vendor
    /// or employee), oldest first — or against `target` alone when given.
    /// Surplus becomes a pre-payment. Returns the payment transaction.
    @discardableResult
    func processPayment(owner: BusinessOwner, amount: Decimal,
                        from bankAccount: Account, to postingAccount: Account,
                        on date: Date, applyTo target: Invoice? = nil,
                        memo: String = "Payment") throws -> Transaction {
        let receivable = owner.postingAccountType == .receivable
        guard postingAccount.type == owner.postingAccountType else {
            throw BusinessError.wrongPostingAccount
        }

        let openInvoices: [Invoice]
        if let target {
            guard target.isPosted, target.owner.guid == owner.guid else {
                throw BusinessError.notPosted
            }
            openInvoices = [target]
        } else {
            openInvoices = invoices(forOwner: owner.guid)
                .filter { $0.isPosted && $0.postedAccount === postingAccount
                          && outstanding($0) > 0 }
                .sorted { ($0.datePosted ?? .distantPast) < ($1.datePosted ?? .distantPast) }
        }

        let txn = Transaction(currency: bankAccount.commodity, datePosted: date,
                              description: owner.displayName)
        txn.kvp["trans-txn-type"] = .string("P")   // GnuCash payment marker
        txn.addSplit(account: bankAccount, value: receivable ? amount : -amount, memo: memo)
            .action = "Payment"

        var remaining = amount
        for invoice in openInvoices {
            guard remaining > 0, let lot = invoice.postedLot else { continue }
            let portion = min(remaining, outstanding(invoice))
            guard portion > 0 else { continue }
            let split = txn.addSplit(account: postingAccount,
                                     value: receivable ? -portion : portion, memo: memo)
            split.action = "Payment"
            lot.add(split)
            remaining -= portion
        }

        // Surplus: a pre-payment the owner now has credit for.
        if remaining > 0 {
            let split = txn.addSplit(account: postingAccount,
                                     value: receivable ? -remaining : remaining, memo: memo)
            split.action = "Payment"
            let lot = Lot(account: postingAccount, title: "Pre-payment")
            lot.kvp["gncOwner"] = .frame(KvpFrame([
                "owner-type": .int64(Self.gncOwnerType(owner)),
                "owner-guid": .guid(owner.guid)]))
            lot.add(split)
            addLot(lot)
        }

        addTransaction(txn)
        return txn
    }
}

// MARK: - Aging

/// Outstanding amounts split into the conventional receivables/payables aging
/// buckets, by how far past due each open invoice is.
public struct AgingBuckets: Sendable, Equatable {
    /// Not yet due, or up to 30 days overdue.
    public var current: Decimal = 0
    public var days31to60: Decimal = 0
    public var days61to90: Decimal = 0
    public var over90: Decimal = 0

    public init(current: Decimal = 0, days31to60: Decimal = 0,
                days61to90: Decimal = 0, over90: Decimal = 0) {
        self.current = current; self.days31to60 = days31to60
        self.days61to90 = days61to90; self.over90 = over90
    }

    public var total: Decimal { current + days31to60 + days61to90 + over90 }

    /// Adds `amount` into the bucket for `daysOverdue`.
    mutating func add(_ amount: Decimal, daysOverdue: Int) {
        switch daysOverdue {
        case ..<31: current += amount
        case 31...60: days31to60 += amount
        case 61...90: days61to90 += amount
        default: over90 += amount
        }
    }
}

public extension Book {

    /// Aging of one owner's open invoices as of `asOf`, bucketed by due date
    /// (GnuCash's 0-30 / 31-60 / 61-90 / 91+).
    func aging(forOwner ownerGuid: GncGUID, asOf: Date,
               calendar: Calendar = .current) -> AgingBuckets {
        var buckets = AgingBuckets()
        for invoice in invoices(forOwner: ownerGuid) where invoice.isPosted {
            let due = outstanding(invoice)
            guard due > 0 else { continue }
            let dueDate = invoice.dueDate ?? invoice.datePosted ?? asOf
            let days = calendar.dateComponents([.day], from: dueDate, to: asOf).day ?? 0
            buckets.add(due, daysOverdue: days)
        }
        return buckets
    }

    /// Per-owner aging for every customer (`receivable`) or vendor
    /// (`!receivable`) with an outstanding balance, most-owing first.
    func agingByOwner(receivable: Bool, asOf: Date,
                      calendar: Calendar = .current) -> [(name: String, buckets: AgingBuckets)] {
        let owners: [(GncGUID, String)] = receivable
            ? customers.map { ($0.guid, $0.name) }
            : vendors.map { ($0.guid, $0.name) }
        return owners
            .map { ($0.1, aging(forOwner: $0.0, asOf: asOf, calendar: calendar)) }
            .filter { $0.1.total != 0 }
            .sorted { $0.1.total > $1.1.total }
            .map { (name: $0.0, buckets: $0.1) }
    }
}
