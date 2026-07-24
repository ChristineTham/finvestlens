//
//  AppModel+Session.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Session restoration (F18): where you were survives relaunch. The sidebar
//  destination — including the selected account — is stored per book (keyed
//  by file path) and re-applied when that book finishes opening. Held in
//  UserDefaults, not the book: where you were looking is desk state, not
//  accounting data, and must not dirty the document (the same reasoning as
//  the per-account register sort/filter state).
//

import Foundation
import FinvestLensEngine

@MainActor
extension AppModel {

    private var sessionSelectionKey: String? {
        documentURL.map { "session.sidebarSelection:\($0.standardizedFileURL.path)" }
    }

    /// Called from `sidebarSelection.didSet` — every navigation updates the
    /// stored destination for this book.
    func persistSessionSelection() {
        guard isOpen, let key = sessionSelectionKey else { return }
        UserDefaults.standard.set(Self.encode(sidebarSelection ?? .dashboard), forKey: key)
    }

    /// Re-applies the stored destination once a book is open. An account that
    /// no longer exists (deleted, or the file changed outside the app) falls
    /// back to the dashboard rather than a dead selection.
    func restoreSessionSelection() {
        guard let key = sessionSelectionKey,
              let raw = UserDefaults.standard.string(forKey: key),
              let selection = Self.decodeSelection(raw) else { return }
        if case .account(let id) = selection, book?.account(with: id) == nil { return }
        sidebarSelection = selection
    }

    private static func encode(_ selection: SidebarSelection) -> String {
        switch selection {
        case .dashboard: "dashboard"
        case .account(let id): "account:\(id.hexString)"
        case .reports: "reports"
        case .generalLedger: "generalLedger"
        case .budgets: "budgets"
        case .scheduled: "scheduled"
        case .rules: "rules"
        case .goals: "goals"
        case .prices: "prices"
        case .business: "business"
        case .timeMileage: "timeMileage"
        case .planner: "planner"
        case .emergencyRecords: "emergencyRecords"
        }
    }

    private static func decodeSelection(_ raw: String) -> SidebarSelection? {
        if raw.hasPrefix("account:") {
            return GncGUID(hex: String(raw.dropFirst("account:".count))).map(SidebarSelection.account)
        }
        switch raw {
        case "dashboard": return .dashboard
        case "reports": return .reports
        case "generalLedger": return .generalLedger
        case "budgets": return .budgets
        case "scheduled": return .scheduled
        case "rules": return .rules
        case "planner": return .planner
        case "emergencyRecords": return .emergencyRecords
        case "goals": return .goals
        case "prices": return .prices
        case "business": return .business
        case "timeMileage": return .timeMileage
        default: return nil
        }
    }
}
