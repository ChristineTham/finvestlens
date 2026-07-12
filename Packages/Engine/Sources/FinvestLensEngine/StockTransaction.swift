//
//  StockTransaction.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The security-transaction shapes the Stock Transaction Assistant can build
/// (`FR-INV-05`).
public enum StockActionKind: String, CaseIterable, Sendable, Identifiable {
    case buy
    case sell
    case dividend
    case reinvestDividend
    case split

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .buy: return "Buy"
        case .sell: return "Sell"
        case .dividend: return "Dividend"
        case .reinvestDividend: return "Reinvest Dividend"
        case .split: return "Split"
        }
    }

    /// Whether the action moves shares (needs a price/share count).
    public var movesShares: Bool { self != .dividend }
}

/// Builds correctly-signed, balanced multi-split ``Transaction``s for security
/// activity. The realised gain on a sale is not booked as a split — it is
/// derived analytically by ``CostBasis`` from the disposal's proceeds.
public enum StockTransaction {

    /// Buy `shares` at `pricePerShare`, paying `commission`, settled from
    /// `cash`. Commission is expensed to `commissionAccount` when supplied.
    ///
    /// Splits: security +cost/+shares, [commission +fee], cash −(cost+fee).
    public static func buy(
        security: Account, cash: Account, commissionAccount: Account? = nil,
        shares: Decimal, pricePerShare: Decimal, commission: Decimal = 0,
        date: Date, currency: Commodity, description: String, memo: String = ""
    ) -> Transaction {
        let cost = currency.round(shares * pricePerShare)
        let fee = currency.round(commission)
        let txn = Transaction(currency: currency, datePosted: date, description: description)
        txn.addSplit(account: security, value: cost, quantity: shares, memo: memo)
        if fee != 0, let commissionAccount {
            txn.addSplit(account: commissionAccount, value: fee, memo: "Commission")
        }
        txn.addSplit(account: cash, value: -(cost + fee))
        return txn
    }

    /// Sell `shares` at `pricePerShare`, paying `commission`, proceeds settled to
    /// `cash`.
    ///
    /// Splits: security −gross/−shares, [commission +fee], cash +(gross−fee).
    /// Proceeds for gain purposes are the gross amount; commission is expensed
    /// separately.
    public static func sell(
        security: Account, cash: Account, commissionAccount: Account? = nil,
        shares: Decimal, pricePerShare: Decimal, commission: Decimal = 0,
        date: Date, currency: Commodity, description: String, memo: String = ""
    ) -> Transaction {
        let gross = currency.round(shares * pricePerShare)
        let fee = currency.round(commission)
        let txn = Transaction(currency: currency, datePosted: date, description: description)
        txn.addSplit(account: security, value: -gross, quantity: -shares, memo: memo)
        if fee != 0, let commissionAccount {
            txn.addSplit(account: commissionAccount, value: fee, memo: "Commission")
        }
        txn.addSplit(account: cash, value: gross - fee)
        return txn
    }

    /// A cash dividend of `amount` from `income` credited to `cash`.
    ///
    /// Splits: income −amount (credit), cash +amount.
    public static func dividend(
        income: Account, cash: Account, amount: Decimal,
        date: Date, currency: Commodity, description: String, memo: String = ""
    ) -> Transaction {
        let value = currency.round(amount)
        let txn = Transaction(currency: currency, datePosted: date, description: description)
        txn.addSplit(account: income, value: -value, memo: memo)
        txn.addSplit(account: cash, value: value)
        return txn
    }

    /// A dividend of `amount` reinvested into `shares` of `security`.
    ///
    /// Splits: income −amount (credit), security +amount/+shares.
    public static func reinvestDividend(
        income: Account, security: Account, shares: Decimal, amount: Decimal,
        date: Date, currency: Commodity, description: String, memo: String = ""
    ) -> Transaction {
        let value = currency.round(amount)
        let txn = Transaction(currency: currency, datePosted: date, description: description)
        txn.addSplit(account: income, value: -value, memo: memo)
        txn.addSplit(account: security, value: value, quantity: shares)
        return txn
    }

    /// A stock split adding `addedShares` (negative for a reverse split) to
    /// `security` at zero cost. A single split marked `action = "Split"` so the
    /// cost-basis engine rescales the open lots rather than adding a parcel.
    public static func stockSplit(
        security: Account, addedShares: Decimal,
        date: Date, currency: Commodity, description: String, memo: String = ""
    ) -> Transaction {
        let txn = Transaction(currency: currency, datePosted: date, description: description)
        let split = Split(account: security, value: 0, quantity: addedShares, memo: memo, action: "Split")
        txn.addSplit(split)
        return txn
    }
}
