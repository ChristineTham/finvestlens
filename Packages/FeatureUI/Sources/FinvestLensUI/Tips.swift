//
//  Tips.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  In-context feature discovery (TipKit). Tips are rule-based and
//  frequency-capped by the system, and their dismissal syncs across a user's
//  devices — better than a static onboarding wall for a feature-dense app.
//

import SwiftUI
import TipKit

/// Reconciling an account against a bank/broker statement.
struct ReconcileTip: Tip {
    var title: Text { Text("Reconcile against your statement") }
    var message: Text? {
        Text("Enter the statement's closing balance and date — FinvestLens auto-clears the matching transactions and shows any difference left to chase.")
    }
    var image: Image? { Image(systemName: "checkmark.seal") }
}

/// On-device PDF reading (Apple Intelligence).
struct SmartImportTip: Tip {
    var title: Text { Text("Read statements on device") }
    var message: Text? {
        Text("Bank statements, dividend statements and invoices are read on-device by Apple Intelligence and turned into transactions to review — nothing leaves your Mac.")
    }
    var image: Image? { Image(systemName: "doc.viewfinder") }
}

/// Including a whole subtree's postings in the register.
struct SubaccountsTip: Tip {
    var title: Text { Text("See a whole subtree at once") }
    var message: Text? {
        Text("Turn on Subaccounts to include every posting under this account — GnuCash's Open Subaccounts, without a second window.")
    }
    var image: Image? { Image(systemName: "list.bullet.indent") }
}
