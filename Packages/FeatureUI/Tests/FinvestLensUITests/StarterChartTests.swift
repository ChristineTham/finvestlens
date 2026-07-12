//
//  StarterChartTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Starter chart")
struct StarterChartTests {

    @Test("Creates a nested starter chart with heuristic categories")
    func create() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let count = model.createStarterAccounts()
        #expect(count == StarterChart.nodes.count)

        let names = Set(model.postableAccounts.map(\.name))
        #expect(names.contains("Groceries"))
        #expect(names.contains("Cheque Account"))
        // Groceries is nested under Expenses.
        let groceries = model.book!.accounts.first { $0.name == "Groceries" }
        #expect(groceries?.parent?.name == "Expenses")
    }
}
