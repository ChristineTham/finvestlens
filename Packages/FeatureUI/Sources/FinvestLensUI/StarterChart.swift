//
//  StarterChart.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A default personal chart of accounts for onboarding (`FR-COA-03`,
/// `FR-PLAN-09`). Category names align with ``MerchantHeuristics`` so imported
/// transactions auto-categorise out of the box.
enum StarterChart {

    /// A node to create: name, type, and index of its parent in the flat list
    /// (`nil` = top level).
    struct Node { let name: String; let type: AccountType; let parent: Int? }

    static let nodes: [Node] = {
        var list: [Node] = []
        func add(_ name: String, _ type: AccountType, parent: Int? = nil) -> Int {
            list.append(Node(name: name, type: type, parent: parent)); return list.count - 1
        }
        let assets = add("Assets", .asset)
        _ = add("Cheque Account", .bank, parent: assets)
        _ = add("Savings", .bank, parent: assets)
        _ = add("Cash", .cash, parent: assets)

        let liabilities = add("Liabilities", .liability)
        _ = add("Credit Card", .credit, parent: liabilities)

        let equity = add("Equity", .equity)
        _ = add("Opening Balances", .equity, parent: equity)

        let income = add("Income", .income)
        for name in ["Salary", "Interest", "Other Income"] { _ = add(name, .income, parent: income) }

        let expenses = add("Expenses", .expense)
        for name in ["Groceries", "Dining", "Fuel", "Transport", "Rent", "Utilities",
                     "Phone & Internet", "Subscriptions", "Health", "Insurance",
                     "Shopping", "Entertainment", "Other Expenses"] {
            _ = add(name, .expense, parent: expenses)
        }
        return list
    }()
}

@MainActor
extension AppModel {

    /// Creates the starter chart of accounts in the current book if it is empty
    /// (`FR-COA-03`). Returns the number of accounts created.
    @discardableResult
    public func createStarterAccounts() -> Int {
        guard let book else { return 0 }
        var ids: [GncGUID?] = []
        for node in StarterChart.nodes {
            let parentID = node.parent.flatMap { ids[$0] }
            let id = addAccount(name: node.name, type: node.type,
                                commodity: reportCurrency, parentID: parentID)
            ids.append(id)
        }
        return ids.compactMap { $0 }.count
    }
}
