//
//  AppModel+Securities.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

@MainActor
extension AppModel {

    /// Held securities plus watch-list securities (all pricable commodities),
    /// de-duplicated by identity.
    public var pricableSecurities: [Commodity] {
        var seen = Set<String>()
        var result: [Commodity] = []
        for commodity in securityCommodities + watchlist
        where seen.insert("\(commodity.namespace)|\(commodity.mnemonic)").inserted {
            result.append(commodity)
        }
        return result.sorted { $0.mnemonic < $1.mnemonic }
    }

    /// Whether a security is only watched (no holding account).
    public func isWatchOnly(_ commodity: Commodity) -> Bool {
        !securityCommodities.contains(commodity) && watchlist.contains(commodity)
    }

    // MARK: Security editor (`FR-INV-07`)

    /// Renames a security's display name across every account, price and
    /// watch-list entry that uses it. Identity (namespace + mnemonic) is
    /// unchanged, so prices and quotes stay linked.
    public func renameSecurity(_ commodity: Commodity, fullName: String, smallestFraction: Int? = nil) {
        guard let book else { return }
        let trimmed = fullName.trimmingCharacters(in: .whitespaces)
        editingWholeBook(named: "Rename Security") {
            book.updateCommodityMetadata(commodity, fullName: trimmed, smallestFraction: smallestFraction)
            for index in watchlist.indices where watchlist[index] == commodity {
                if !trimmed.isEmpty { watchlist[index].fullName = trimmed }
                if let smallestFraction, smallestFraction >= 1 {
                    watchlist[index].smallestFraction = smallestFraction
                }
            }
            persistKvpCollections()
        }
    }

    // MARK: Watch list (`FR-PLAN-07`)

    /// Adds a watched security (does nothing if already held or watched).
    public func addWatchSecurity(exchange: String, ticker: String, name: String) {
        let code = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return }
        let ex = exchange.trimmingCharacters(in: .whitespaces).uppercased()
        let commodity = Commodity(namespace: .security(ex.isEmpty ? "OTHER" : ex), mnemonic: code,
                                  fullName: name.trimmingCharacters(in: .whitespaces).isEmpty ? code : name,
                                  smallestFraction: 10_000)
        guard !pricableSecurities.contains(commodity) else { return }
        watchlist.append(commodity)
        book?.registerCommodity(commodity)
        commitKvpCollections(named: "Add Watched Security")
    }

    public func removeWatchSecurity(_ commodity: Commodity) {
        watchlist.removeAll { $0 == commodity }
        commitKvpCollections(named: "Remove Watched Security")
    }
}
