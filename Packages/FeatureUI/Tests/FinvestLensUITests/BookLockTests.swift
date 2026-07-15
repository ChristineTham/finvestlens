//
//  BookLockTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Book lock")
struct BookLockTests {

    @Test("Require-auth preference locks on reopen; unlock clears it")
    func lockLifecycle() async throws {
        let url = tempURL()
        let model = AppModel(authenticator: AllowAllAuthenticator())
        try model.newDocument(at: url)
        #expect(model.isLocked == false)             // new books aren't locked
        model.requireAuthentication = true
        try model.save()
        model.close()

        let reopened = AppModel(authenticator: AllowAllAuthenticator())
        try await reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.requireAuthentication)
        #expect(reopened.isLocked)                    // locked on open

        // No biometrics in the test host → unlock succeeds and clears the lock.
        let ok = await reopened.unlock()
        #expect(ok)
        #expect(reopened.isLocked == false)
    }

    @Test("Lock Now locks an open book")
    func lockNow() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        #expect(model.isLocked == false)
        model.lockNow()
        #expect(model.isLocked)
    }
}
