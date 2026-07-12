//
//  AppModel+Currency.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A stored exchange-rate row for the rates editor.
public struct RateRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var from: String
    public var to: String
    public var date: Date
    public var value: Decimal
}

/// Errors from currency operations.
public enum CurrencyEntryError: Error, Equatable {
    case noBook
    case unknownAccount
    case sameCurrency
    case invalidAmount
}

@MainActor
extension AppModel {

    /// Distinct currencies used by the book's accounts.
    public var currencyCommodities: [Commodity] {
        guard let book else { return [] }
        var seen = Set<String>()
        var result: [Commodity] = []
        for account in book.accounts where account.commodity.namespace == .currency {
            if seen.insert(account.commodity.mnemonic).inserted { result.append(account.commodity) }
        }
        return result.sorted { $0.mnemonic < $1.mnemonic }
    }

    /// Records an exchange rate (a price between two currencies).
    public func addExchangeRate(from: Commodity, to: Commodity, rate: Decimal, date: Date) {
        guard let book, rate > 0, from != to else { return }
        book.setExchangeRate(from: from, to: to, rate: rate, date: date, source: "user:rate")
        markDirtyAndRefresh()
    }

    /// Records a cross-currency transfer moving `sourceAmount` out of `fromID`
    /// and `destAmount` into `toID`, and stores the implied rate (`FR-CUR-02`).
    ///
    /// The two legs balance on value (in the source currency); the differing
    /// quantities capture the exchange.
    @discardableResult
    public func recordCurrencyTransfer(
        fromID: GncGUID?, toID: GncGUID?,
        sourceAmount: Decimal, destAmount: Decimal,
        date: Date, description: String
    ) throws -> GncGUID {
        guard let book else { throw CurrencyEntryError.noBook }
        guard let from = fromID.flatMap({ book.account(with: $0) }),
              let to = toID.flatMap({ book.account(with: $0) }) else {
            throw CurrencyEntryError.unknownAccount
        }
        guard from.commodity != to.commodity else { throw CurrencyEntryError.sameCurrency }
        guard sourceAmount > 0, destAmount > 0 else { throw CurrencyEntryError.invalidAmount }

        let txn = Transaction(currency: from.commodity, datePosted: date, description: description)
        // Source leg: value and quantity both in the source currency.
        txn.addSplit(account: from, value: -sourceAmount, quantity: -sourceAmount)
        // Destination leg: value in source currency (balances), quantity in the
        // destination currency (the amount actually received).
        txn.addSplit(account: to, value: sourceAmount, quantity: destAmount)
        book.addTransaction(txn)

        // Persist the implied rate so reports can value either currency.
        book.setExchangeRate(from: from.commodity, to: to.commodity,
                             rate: destAmount / sourceAmount, date: date, source: "user:xfer")
        markDirtyAndRefresh()
        return txn.guid
    }
}
