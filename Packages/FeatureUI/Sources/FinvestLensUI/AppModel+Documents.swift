//
//  AppModel+Documents.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Transaction document links (`FR-AI-08`), modelled on GnuCash's
//  associations: a transaction carries an `assoc_uri` slot holding either an
//  absolute `file://` URI or a path **relative to the document folder** — a
//  user setting (GnuCash's "path head"), defaulting to the folder the book
//  lives in so links stay valid when a book and its documents move together
//  (e.g. on a NAS).
//

import Foundation
import FinvestLensEngine
#if os(macOS)
import AppKit
#endif

@MainActor
extension AppModel {

    static let documentFolderDefaultsKey = "finvestlens.documentFolderPath"

    // MARK: New-book placement

    /// A non-colliding URL for a new book in `directory`: `Untitled`,
    /// `Untitled 2`, `Untitled 3`, … On iOS the caller passes the app's
    /// Documents directory — user-visible in Files under
    /// "On My iPhone ▸ finvestlens" — never the purgeable temporary
    /// directory. A leftover sibling `.lock` also counts as a collision, so
    /// a new book can never adopt a stale lock.
    public static func newBookURL(in directory: URL,
                                  baseName: String = "Untitled") -> URL {
        func candidate(_ index: Int) -> URL {
            let name = index == 1 ? baseName : "\(baseName) \(index)"
            return directory.appendingPathComponent(name)
                .appendingPathExtension("finvestlens")
        }
        var index = 1
        while FileManager.default.fileExists(atPath: candidate(index).path)
            || FileManager.default.fileExists(
                atPath: candidate(index).deletingPathExtension()
                    .appendingPathExtension("lock").path) {
            index += 1
        }
        return candidate(index)
    }

    // MARK: Folder setting

    /// The user-chosen document folder, or `nil` to use the book's folder.
    public var configuredDocumentFolder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Self.documentFolderDefaultsKey),
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            UserDefaults.standard.set(newValue?.path ?? "", forKey: Self.documentFolderDefaultsKey)
        }
    }

    /// Where relative document links resolve: the configured folder, else the
    /// folder containing the open book.
    public var effectiveDocumentFolder: URL? {
        configuredDocumentFolder ?? documentURL?.deletingLastPathComponent()
    }

    // MARK: Attach / resolve

    /// Copies a document into the document folder (reusing an identical
    /// existing file, uniquing the name otherwise) and links it to the
    /// transaction as a relative path.
    ///
    /// - Returns: the stored link.
    @discardableResult
    public func attachDocument(named name: String, data: Data,
                               to transactionID: GncGUID) throws -> String {
        guard let book, let transaction = book.transaction(with: transactionID) else {
            throw TransactionEntryError.notFound
        }
        guard let folder = effectiveDocumentFolder else {
            throw DocumentLinkError.noFolder
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var counter = 2
        while true {
            let target = folder.appendingPathComponent(candidate)
            if let existing = try? Data(contentsOf: target) {
                if existing == data { break }  // same document already stored
                candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                counter += 1
            } else {
                try data.write(to: target, options: .atomic)
                break
            }
        }
        // Only the link is undoable — the copied file stays on disk.
        editing([transactionID], named: "Attach Document") {
            transaction.documentLink = candidate
        }
        return candidate
    }

    /// Resolves a transaction's document link to a file URL: absolute
    /// `file://` URIs as-is, plain paths relative to the document folder
    /// (absolute paths are honoured too).
    public func linkedDocumentURL(for transactionID: GncGUID) -> URL? {
        guard let link = book?.transaction(with: transactionID)?.documentLink else { return nil }
        if link.hasPrefix("file://") {
            return URL(string: link)
        }
        if link.hasPrefix("/") {
            return URL(fileURLWithPath: link)
        }
        return effectiveDocumentFolder?.appendingPathComponent(link)
    }

    public func hasLinkedDocument(_ transactionID: GncGUID) -> Bool {
        book?.transaction(with: transactionID)?.documentLink != nil
    }

    /// Opens the linked document in its default application (macOS).
    public func openLinkedDocument(for transactionID: GncGUID) {
        #if os(macOS)
        guard let url = linkedDocumentURL(for: transactionID) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            infoMessage = "The linked document “\(url.lastPathComponent)” was not found in \(url.deletingLastPathComponent().path)."
        }
        #endif
    }

    public enum DocumentLinkError: LocalizedError {
        case noFolder

        public var errorDescription: String? {
            switch self {
            case .noFolder:
                return "No document folder is available — open a book or choose a folder in Settings."
            }
        }
    }
}
