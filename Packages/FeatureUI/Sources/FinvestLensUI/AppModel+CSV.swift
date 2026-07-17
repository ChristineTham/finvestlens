//
//  AppModel+CSV.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange

/// Which slice of the book a CSV export covers (`FR-XIO-06`).
public enum CSVExportKind: String, Sendable, CaseIterable, Identifiable {
    case accounts, transactions, prices
    public var id: String { rawValue }

    public var menuTitle: String {
        switch self {
        case .accounts: return "Accounts…"
        case .transactions: return "Transactions…"
        case .prices: return "Prices…"
        }
    }

    /// Suggested export filename stem.
    public func filename(book bookName: String) -> String {
        "\(bookName) \(rawValue.capitalized)"
    }
}

@MainActor
extension AppModel {

    /// Renders the requested slice of the open book to CSV (`FR-XIO-06`).
    public func csvExport(_ kind: CSVExportKind) -> String {
        guard let book else { return "" }
        switch kind {
        case .accounts:     return CSVExporter.accounts(book)
        case .transactions: return CSVExporter.transactions(book)
        case .prices:       return CSVExporter.prices(book)
        }
    }
}
