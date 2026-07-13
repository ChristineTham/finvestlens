//
//  DocumentLinkTests.swift
//  FinvestLens — FeatureUI
//
//  Transaction document links (`FR-AI-08`): storing PDFs in the document
//  folder, relative-link resolution against the setting (or the book's
//  folder), name collisions, and identical-file reuse.
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
@Suite("Document links", .serialized)
struct DocumentLinkTests {

    /// Runs `body` with a clean document-folder setting, restoring it after.
    private func withCleanSetting(_ body: (AppModel) throws -> Void) throws {
        let saved = UserDefaults.standard.string(forKey: AppModel.documentFolderDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppModel.documentFolderDefaultsKey)
        defer {
            UserDefaults.standard.set(saved ?? "", forKey: AppModel.documentFolderDefaultsKey)
        }
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        try body(model)
    }

    private func makeTransaction(_ model: AppModel) throws -> GncGUID {
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let shopping = try #require(model.addAccount(name: "Shopping", type: .expense))
        return try model.addTransaction(
            date: Date(), description: "SHOP", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -50),
                     SplitInput(accountID: shopping, value: 50)]
        )
    }

    @Test("Attaching stores the file next to the book and links it relatively")
    func attachDefaultFolder() throws {
        try withCleanSetting { model in
            let id = try makeTransaction(model)
            let data = Data("INVOICE".utf8)
            let link = try model.attachDocument(named: "invoice.pdf", data: data, to: id)
            #expect(link == "invoice.pdf")

            // Stored next to the book, resolvable, and on the transaction.
            let resolved = try #require(model.linkedDocumentURL(for: id))
            #expect(resolved.deletingLastPathComponent().path
                    == model.documentURL?.deletingLastPathComponent().path)
            #expect(try Data(contentsOf: resolved) == data)
            #expect(model.hasLinkedDocument(id))
            #expect(model.book?.transaction(with: id)?.documentLink == "invoice.pdf")

            // Same name + same content → reused, not duplicated.
            #expect(try model.attachDocument(named: "invoice.pdf", data: data, to: id) == "invoice.pdf")
            // Same name + different content → uniqued.
            let other = try model.attachDocument(named: "invoice.pdf",
                                                 data: Data("OTHER".utf8), to: id)
            #expect(other == "invoice 2.pdf")
        }
    }

    @Test("A configured folder overrides the book folder")
    func configuredFolder() throws {
        try withCleanSetting { model in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("finvestlens-docs-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            model.configuredDocumentFolder = folder

            let id = try makeTransaction(model)
            let link = try model.attachDocument(named: "statement.pdf",
                                                data: Data("S".utf8), to: id)
            #expect(link == "statement.pdf")
            let resolved = try #require(model.linkedDocumentURL(for: id))
            #expect(resolved.deletingLastPathComponent().path == folder.path)
        }
    }

    @Test("Absolute and file:// links resolve as-is")
    func absoluteLinks() throws {
        try withCleanSetting { model in
            let id = try makeTransaction(model)
            let book = try #require(model.book)
            let transaction = try #require(book.transaction(with: id))

            transaction.documentLink = "/tmp/somewhere/doc.pdf"
            #expect(model.linkedDocumentURL(for: id)?.path == "/tmp/somewhere/doc.pdf")

            transaction.documentLink = "file:///tmp/other/doc.pdf"
            #expect(model.linkedDocumentURL(for: id)?.path == "/tmp/other/doc.pdf")

            transaction.documentLink = nil
            #expect(!model.hasLinkedDocument(id))
            #expect(model.linkedDocumentURL(for: id) == nil)
        }
    }
}
