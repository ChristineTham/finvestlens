//
//  AccountType.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// The GnuCash account types.
///
/// Raw values match GnuCash's XML type strings so that import/export mapping is
/// direct. Classification helpers describe balance-sheet vs income-statement
/// placement and the sign convention used for running balances.
public enum AccountType: String, Codable, CaseIterable, Sendable {
    case root = "ROOT"
    case asset = "ASSET"
    case bank = "BANK"
    case cash = "CASH"
    case credit = "CREDIT"
    case liability = "LIABILITY"
    case equity = "EQUITY"
    case income = "INCOME"
    case expense = "EXPENSE"
    case receivable = "RECEIVABLE"
    case payable = "PAYABLE"
    case stock = "STOCK"
    case mutualFund = "MUTUAL"
    case trading = "TRADING"

    /// Asset-like types (debit-normal) — bank, cash, stock, receivable, etc.
    public var isAssetLike: Bool {
        switch self {
        case .asset, .bank, .cash, .stock, .mutualFund, .receivable:
            return true
        default:
            return false
        }
    }

    /// Liability/equity/income types (credit-normal).
    public var isLiabilityLike: Bool {
        switch self {
        case .liability, .credit, .equity, .income, .payable:
            return true
        default:
            return false
        }
    }

    /// `true` if a positive posting **increases** the account's balance under
    /// its normal sign (debit-normal accounts). Used for register presentation.
    public var normalBalanceIsDebit: Bool {
        switch self {
        case .asset, .bank, .cash, .stock, .mutualFund, .receivable, .expense, .trading:
            return true
        default:
            return false
        }
    }

    /// Whether this type holds securities (priced in a non-currency commodity).
    public var isSecurityType: Bool {
        self == .stock || self == .mutualFund
    }
}
