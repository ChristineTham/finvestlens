//
//  SavedSearchTests.swift
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
@Suite("Saved searches")
struct SavedSearchTests {

    @Test("Save, persist, reopen, apply")
    func lifecycle() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        model.searchQuery = "tag:work amount:>100"
        model.saveCurrentSearch(name: "Big work")
        #expect(model.savedSearches.count == 1)
        try model.save()
        model.close()

        let reopened = AppModel()
        try reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.savedSearches.first?.name == "Big work")
        reopened.applySavedSearch(reopened.savedSearches.first!.id)
        #expect(reopened.searchQuery == "tag:work amount:>100")
    }
}
