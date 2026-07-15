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
    func recentsBookmark() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = AppModel()
        try model.newDocument(at: url)
        model.close()
        try await model.open(at: url)
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

    @Test("A recent whose book has been deleted drops out of the list")
    func deletedRecentIsDropped() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        model.close()

        // Present while the file is there — including its bookmark.
        #expect(bookmarks[url.path] != nil)
        #expect(AppModel.loadRecents().contains { $0.path == url.path })

        // Deleting the book must not leave the entry behind: the bookmark
        // alone used to keep it in the list forever.
        try FileManager.default.removeItem(at: url)
        #expect(!AppModel.loadRecents().contains { $0.path == url.path })
    }

    @Test("Opening a missing recent prunes it and reports the failure")
    func openingMissingRecentPrunesIt() async throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        model.close()
        try FileManager.default.removeItem(at: url)

        // The entry survives in UserDefaults until something tries to use it.
        let paths = { UserDefaults.standard.stringArray(forKey: "finvestlens.recentBookPaths") ?? [] }
        #expect(paths().contains(url.path))

        await model.openBook(at: url)
        #expect(model.documentError != nil)       // the user is told
        #expect(!model.isOpen)
        #expect(!paths().contains(url.path))      // …and it won't be offered again
        #expect(bookmarks[url.path] == nil)
    }

    @Test("Re-opening the already-open book is a no-op, not a close-and-reload")
    func reopeningSameBookIsNoOp() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        let account = try #require(model.addAccount(name: "Bank", type: .bank))

        // A second click on the same recent must not tear the book down: the
        // document instance survives and unsaved work with it.
        let before = model.document
        await model.openBook(at: url)
        #expect(model.isOpen)
        #expect(model.document === before)
        #expect(model.documentError == nil)
        #expect(model.accountTree.contains { $0.id == account })
    }

    @Test("A missing file is recognised, a locked book is not")
    func missingFileErrorClassification() async throws {
        // Pin the real error the open path throws for a missing book, so the
        // prune in openBook can't silently stop matching.
        let missing = tempURL()
        await #expect(throws: (any Error).self) { try await AppModel().open(at: missing) }
        do {
            try await AppModel().open(at: missing)
            Issue.record("expected open to throw for a missing file")
        } catch {
            #expect(AppModel.isMissingFileError(error))
            #expect(!AppModel.isLockedError(error))
        }

        // A locked book is a different failure — the entry must be kept.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let holder = AppModel()
        try holder.newDocument(at: url)
        defer { holder.close() }
        do {
            try await AppModel().open(at: url)
            Issue.record("expected open to throw for a locked book")
        } catch {
            #expect(AppModel.isLockedError(error))
            #expect(!AppModel.isMissingFileError(error))
        }
    }

    @Test("New-book URLs avoid existing books and stale locks")
    func newBookNaming() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Empty folder → plain "Untitled".
        #expect(AppModel.newBookURL(in: folder).lastPathComponent == "Untitled.finvestlens")

        // Existing book → "Untitled 2"; stale lock for 2 → skip to 3.
        try Data().write(to: folder.appendingPathComponent("Untitled.finvestlens"))
        #expect(AppModel.newBookURL(in: folder).lastPathComponent == "Untitled 2.finvestlens")
        try Data().write(to: folder.appendingPathComponent("Untitled 2.lock"))
        #expect(AppModel.newBookURL(in: folder).lastPathComponent == "Untitled 3.finvestlens")

        // The URL actually works end-to-end for creating a book.
        let model = AppModel()
        try model.newDocument(at: AppModel.newBookURL(in: folder))
        defer { model.close() }
        #expect(model.isOpen)
        #expect(model.documentURL?.lastPathComponent == "Untitled 3.finvestlens")
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("Untitled 3.finvestlens").path))
    }

    @Test("A book in a read-only folder opens lockless (provider-style grant)")
    func openLockless() async throws {
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
        try await model.open(at: url)
        defer { model.close() }
        #expect(model.isOpen)
        #expect(model.accountTree.contains { $0.name == "Bank" })
    }
}
