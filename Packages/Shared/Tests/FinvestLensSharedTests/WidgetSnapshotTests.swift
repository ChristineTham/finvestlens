//
//  WidgetSnapshotTests.swift
//  FinvestLens — Shared
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import FinvestLensShared

struct WidgetSnapshotTests {

    @Test func roundTripsThroughJSON() throws {
        let snap = WidgetSnapshot(
            bookName: "Ashley Bears",
            netWorth: "$1,234.00",
            upcomingBills: "2 bills due · $50.00",
            alerts: [.init(title: "Bill due", message: "Rent", severity: 2)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded == snap)
    }

    @Test func appGroupIdentifierMatchesEntitlement() {
        #expect(SharedAppGroup.identifier == "group.com.hellotham.finvestlensapp")
    }

    @Test func placeholderIsStable() {
        #expect(WidgetSnapshot.placeholder.bookName == "FinvestLens")
        #expect(WidgetSnapshot.placeholder.alerts.isEmpty)
    }
}
