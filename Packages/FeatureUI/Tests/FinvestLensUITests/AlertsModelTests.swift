//
//  AlertsModelTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Alerts & price targets (AppModel)")
struct AlertsModelTests {

    @Test("Price target persists and raises an alert")
    func priceTargetAlert() async throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)

        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        _ = model.addAccount(name: "CBA", type: .stock, commodity: cba)
        model.addPrice(commodity: cba, currency: .aud, date: Date(timeIntervalSince1970: 0), value: dec("120"))
        model.setPriceTarget(cba, target: dec("100"), direction: .atOrAbove)

        #expect(model.priceTarget(for: cba)?.target == dec("100"))
        #expect(model.alerts().contains { $0.kind == .priceTarget })

        try model.save(); model.close()
        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.priceTargets.count == 1)
    }

    @Test("No conditions → no alerts")
    func noAlerts() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = model.addAccount(name: "Bank", type: .bank)
        #expect(model.alerts().isEmpty)
    }
}
