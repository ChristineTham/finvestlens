//
//  BillableEntry.swift
//  FinvestLens — Engine
//
//  Billable time and mileage (`FR-PLAN-14`): logged work or travel that can be
//  gathered onto a customer invoice. Each entry names the customer to bill, a
//  quantity (hours or distance) and a rate; `amount` is their product. Entries
//  are stored as one JSON collection in a book KVP slot and marked billed once
//  they land on an invoice. GnuCash has no time-tracking module, so this follows
//  the app's own planning model (PRD §5.16), not a GnuCash source.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A logged unit of billable work or travel.
public struct BillableEntry: Identifiable, Codable, Hashable, Sendable {

    /// What is being logged — hours worked, or distance travelled.
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case time, mileage
        public var id: String { rawValue }
        /// The noun for the quantity column.
        public var quantityLabel: String { self == .time ? "Hours" : "Distance" }
    }

    public var id: GncGUID
    public var kind: Kind
    public var date: Date
    /// The customer this entry will be billed to (nil until assigned).
    public var customerID: GncGUID?
    /// An optional job to attribute the work to.
    public var jobID: GncGUID?
    public var detail: String
    /// Hours worked, or distance travelled.
    public var quantity: Decimal
    /// Charge per hour / per unit distance.
    public var rate: Decimal
    /// The income account the invoice line books to (nil = choose at billing).
    public var incomeAccountID: GncGUID?
    /// Set once the entry has been placed on an invoice.
    public var billed: Bool

    public init(id: GncGUID = .random(), kind: Kind = .time, date: Date = Date(),
                customerID: GncGUID? = nil, jobID: GncGUID? = nil, detail: String = "",
                quantity: Decimal = 0, rate: Decimal = 0,
                incomeAccountID: GncGUID? = nil, billed: Bool = false) {
        self.id = id; self.kind = kind; self.date = date
        self.customerID = customerID; self.jobID = jobID; self.detail = detail
        self.quantity = quantity; self.rate = rate
        self.incomeAccountID = incomeAccountID; self.billed = billed
    }

    /// Older slots predate `jobID`/`incomeAccountID`; decode them as absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(GncGUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        date = try c.decode(Date.self, forKey: .date)
        customerID = try c.decodeIfPresent(GncGUID.self, forKey: .customerID)
        jobID = try c.decodeIfPresent(GncGUID.self, forKey: .jobID)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        quantity = try c.decode(Decimal.self, forKey: .quantity)
        rate = try c.decode(Decimal.self, forKey: .rate)
        incomeAccountID = try c.decodeIfPresent(GncGUID.self, forKey: .incomeAccountID)
        billed = try c.decodeIfPresent(Bool.self, forKey: .billed) ?? false
    }

    /// The charge for this entry: quantity × rate.
    public var amount: Decimal { quantity * rate }
}
