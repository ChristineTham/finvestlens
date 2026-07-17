//
//  LinkedDocumentsListTests.swift
//  FinvestLens — FeatureUI
//
//  The book-wide roll-up of transactions with attached documents
//  (GnuCash's Tools ▸ Transaction Linked Documents).
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
private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@MainActor
@Suite("Linked documents list")
struct LinkedDocumentsListTests {

    @Test("Lists every linked transaction, newest first, flagging missing files")
    func rollUp() throws {
        let url = tempURL()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel()
        try model.newDocument(at: url)
        let priorFolder = model.configuredDocumentFolder
        model.configuredDocumentFolder = folder
        defer {
            model.configuredDocumentFolder = priorFolder
            model.close()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: folder)
        }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let expense = try #require(model.addAccount(name: "Office", type: .expense))
        let older = try model.addTransaction(
            date: Date(timeIntervalSince1970: 1_000_000), description: "Older",
            currency: .aud, splits: [SplitInput(accountID: expense, value: dec("10")),
                                     SplitInput(accountID: bank, value: dec("-10"))])
        let newer = try model.addTransaction(
            date: Date(timeIntervalSince1970: 2_000_000), description: "Newer",
            currency: .aud, splits: [SplitInput(accountID: expense, value: dec("20")),
                                     SplitInput(accountID: bank, value: dec("-20"))])
        let plain = try model.addTransaction(
            date: Date(timeIntervalSince1970: 3_000_000), description: "No doc",
            currency: .aud, splits: [SplitInput(accountID: expense, value: dec("5")),
                                     SplitInput(accountID: bank, value: dec("-5"))])

        try model.attachDocument(named: "older.pdf", data: Data("a".utf8), to: older)
        try model.attachDocument(named: "newer.pdf", data: Data("b".utf8), to: newer)

        var docs = model.linkedDocuments()
        #expect(docs.count == 2)                       // the plain txn is excluded
        #expect(docs.first?.description == "Newer")     // newest first
        #expect(docs.allSatisfy { $0.exists })
        #expect(!docs.contains { $0.id == plain })

        // Deleting the file behind a link surfaces as "missing", not a crash.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("newer.pdf"))
        docs = model.linkedDocuments()
        let newerDoc = try #require(docs.first { $0.description == "Newer" })
        #expect(!newerDoc.exists)
        #expect(docs.first { $0.description == "Older" }?.exists == true)
    }

    @Test("A web link is always considered present")
    func webLink() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let expense = try #require(model.addAccount(name: "Office", type: .expense))
        let txn = try model.addTransaction(
            date: Date(timeIntervalSince1970: 1_000), description: "Web",
            currency: .aud, splits: [SplitInput(accountID: expense, value: dec("1")),
                                     SplitInput(accountID: bank, value: dec("-1"))])
        model.book?.transaction(with: txn)?.documentLink = "https://example.com/receipt"

        let doc = try #require(model.linkedDocuments().first)
        #expect(doc.isWeb)
        #expect(doc.exists)
        #expect(doc.displayName == "https://example.com/receipt")
    }
}
