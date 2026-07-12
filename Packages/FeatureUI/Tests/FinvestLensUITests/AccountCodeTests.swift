//
//  AccountCodeTests.swift
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
@Suite("Account renumber")
struct AccountCodeTests {

    @Test("Renumber assigns sequential zero-padded codes")
    func renumber() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let parent = try #require(model.addAccount(name: "Assets", type: .asset))
        _ = model.addAccount(name: "Bank", type: .bank, parentID: parent)
        _ = model.addAccount(name: "Cash", type: .cash, parentID: parent)
        _ = model.addAccount(name: "Savings", type: .bank, parentID: parent)

        model.renumberChildren(of: parent)

        let codes = model.book!.account(with: parent)!.children
            .sorted { $0.name < $1.name }
            .map(\.code)
        #expect(codes == ["10", "20", "30"])
    }
}
