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

    /// The currency a transaction touching these accounts should be recorded
    /// in: the first cash account's currency, else the book's base currency.
    public func transactionCurrency(for accountIDs: [GncGUID]) -> Commodity {
        for id in accountIDs {
            if let commodity = book?.account(with: id)?.commodity,
               commodity.namespace == .currency {
                return commodity
            }
        }
        return reportCurrency
    }

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
        editingPrices(named: "Add Exchange Rate") {
            book.setExchangeRate(from: from, to: to, rate: rate, date: date, source: "user:rate")
        }
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

        // Whole-book, not `editing`: the implied rate is a price, which lives
        // outside any transaction, and the trading accounts are created on
        // demand — both have to happen inside the snapshot to be undone.
        editingWholeBook(named: "Record Currency Transfer") {
            // Optional trading accounts make the transaction balance in *each*
            // currency (not just by value), so the balance sheet stays balanced
            // and unrealised FX is captured (`FR-REG-07`).
            if useTradingAccounts,
               let tradingFrom = tradingAccount(for: from.commodity),
               let tradingTo = tradingAccount(for: to.commodity) {
                txn.addSplit(account: tradingFrom, value: sourceAmount, quantity: sourceAmount)
                txn.addSplit(account: tradingTo, value: -sourceAmount, quantity: -destAmount)
            }
            book.addTransaction(txn)

            // Persist the implied rate so reports can value either currency.
            book.setExchangeRate(from: from.commodity, to: to.commodity,
                                 rate: destAmount / sourceAmount, date: date, source: "user:xfer")
        }
        return txn.guid
    }

    // MARK: Trading accounts (`FR-REG-07`)

    /// Whether cross-currency transfers post to trading accounts (book
    /// preference, persisted in the book KVP).
    public var useTradingAccounts: Bool {
        get {
            if case let .int64(v)? = book?.kvp["finvestlens/useTradingAccounts"] { return v != 0 }
            return false
        }
        set {
            editingBookKvp(named: "Change Trading Accounts Setting") {
                book?.kvp["finvestlens/useTradingAccounts"] = .int64(newValue ? 1 : 0)
            }
        }
    }

    /// The trading account for `currency`, creating the `Trading` tree on first
    /// use.
    public func tradingAccount(for currency: Commodity) -> Account? {
        guard let book else { return nil }
        if let existing = book.accounts.first(where: { $0.type == .trading && $0.commodity == currency && !$0.isPlaceholder }) {
            return existing
        }
        let parent = book.accounts.first { $0.type == .trading && $0.name == "Trading" && $0.isPlaceholder }
            ?? {
                let container = Account(name: "Trading", type: .trading, commodity: reportCurrency)
                container.isPlaceholder = true
                book.addAccount(container)
                return container
            }()
        let account = Account(name: currency.mnemonic, type: .trading, commodity: currency)
        book.addAccount(account, under: parent)
        return account
    }
}
