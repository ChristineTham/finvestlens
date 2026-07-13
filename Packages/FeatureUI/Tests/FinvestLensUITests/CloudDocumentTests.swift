//
//  CloudDocumentTests.swift
//  FinvestLens — FeatureUI
//
//  Books on cloud/provider locations (iCloud Drive, Box, Dropbox): bookmark-
//  backed recents (so Open Recent can regain the iOS security-scoped grant)
//  and lockless open where the sibling `.lock` can't be created.
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
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Cloud documents", .serialized)
struct CloudDocumentTests {

    private var bookmarks: [String: Data] {
        UserDefaults.standard
            .dictionary(forKey: "finvestlens.recentBookBookmarks") as? [String: Data] ?? [:]
    }

    @Test("Opening a book records a resolvable bookmark for recents")
    func recentsBookmark() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = AppModel()
        try model.newDocument(at: url)
        model.close()
        try model.open(at: url)
        defer { model.close() }

        let bookmark = try #require(bookmarks[url.path])
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        #expect(resolved.standardizedFileURL.path == url.standardizedFileURL.path)

        // Recents keep entries that have a bookmark.
        #expect(AppModel.loadRecents().contains { $0.path == url.path })
    }

    @Test("Bookmarks are pruned with the recents list")
    func bookmarkPruning() throws {
        let model = AppModel()
        var urls: [URL] = []
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        for _ in 0..<6 {   // recents cap is 5 — the first must fall out
            let url = tempURL()
            urls.append(url)
            try model.newDocument(at: url)
            model.close()
        }
        #expect(bookmarks[urls[0].path] == nil)
        #expect(bookmarks[urls[5].path] != nil)
    }

    @Test("A book in a read-only folder opens lockless (provider-style grant)")
    func openLockless() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Cloud.finvestlens")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }

        let model = AppModel()
        try model.newDocument(at: url)
        _ = model.addAccount(name: "Bank", type: .bank)
        try model.save()
        model.close()

        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: folder.path)
        try model.open(at: url)
        defer { model.close() }
        #expect(model.isOpen)
        #expect(model.accountTree.contains { $0.name == "Bank" })
    }
}
