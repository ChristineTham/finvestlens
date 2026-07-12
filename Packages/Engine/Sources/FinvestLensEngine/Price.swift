//
//  Price.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A commodity's value in another commodity at a point in time — one entry in
/// the price database (`FR-ENG-09`).
///
/// `value` is the price of one unit of ``commodity`` expressed in ``currency``
/// (e.g. one CBA share = 105.20 AUD).
public struct Price: Identifiable, Codable, Hashable, Sendable {
    public var id: GncGUID { guid }
    public let guid: GncGUID
    /// The thing being priced (a security or a foreign currency).
    public var commodity: Commodity
    /// The commodity the price is expressed in.
    public var currency: Commodity
    public var date: Date
    /// Price of one unit of ``commodity`` in ``currency``.
    public var value: Decimal
    public var source: String
    public var type: String

    public init(guid: GncGUID = .random(), commodity: Commodity, currency: Commodity,
                date: Date, value: Decimal, source: String = "user:price", type: String = "last") {
        self.guid = guid
        self.commodity = commodity
        self.currency = currency
        self.date = date
        self.value = value
        self.source = source
        self.type = type
    }
}
