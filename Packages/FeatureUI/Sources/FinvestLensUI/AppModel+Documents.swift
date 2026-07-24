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
    static let secondaryDocumentFolderDefaultsKey = "finvestlens.documentFolderPathSecondary"

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

    /// An optional fallback: a relative link not found under the primary folder
    /// is also looked for here (e.g. an archive folder, or the old location
    /// after a move).
    public var secondaryDocumentFolder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Self.secondaryDocumentFolderDefaultsKey),
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            UserDefaults.standard.set(newValue?.path ?? "", forKey: Self.secondaryDocumentFolderDefaultsKey)
        }
    }

    // MARK: Cloud files

    /// Whether an iCloud placeholder (`.name.icloud`) sits where `url` should
    /// be — the file is in the cloud, not yet downloaded. (Modern File
    /// Provider files are *dataless* instead: they exist at their real path
    /// and materialise on read, so `fileExists` already reports them.)
    nonisolated static func cloudPlaceholderExists(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    /// Cloud-aware existence: at its path (possibly dataless), or as an iCloud
    /// placeholder awaiting download.
    nonisolated static func fileIsPresentOrInCloud(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || cloudPlaceholderExists(url)
    }

    /// Makes sure `url`'s content is local, asking the cloud to download when
    /// it isn't and polling briefly. Returns whether the file is readable.
    public func ensureLocalFile(_ url: URL, timeout: TimeInterval = 30) async -> Bool {
        await Self.waitForLocalFile(url, timeout: timeout)
    }

    /// The actor-free core of ``ensureLocalFile(_:timeout:)`` — usable from
    /// parallel pipelines.
    nonisolated static func waitForLocalFile(_ url: URL, timeout: TimeInterval = 30) async -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        guard cloudPlaceholderExists(url) else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            if FileManager.default.fileExists(atPath: url.path) { return true }
        }
        return false
    }

    // MARK: Attach / resolve

    /// `attachDocument`, with the failure routed to the status overlay (F20)
    /// — "attach did nothing" was a configuration problem the user never saw
    /// (no document folder, an unwritable folder). Returns success.
    @discardableResult
    public func attachDocumentReporting(named name: String, data: Data,
                                        to transactionID: GncGUID) -> Bool {
        do {
            _ = try attachDocument(named: name, data: data, to: transactionID)
            return true
        } catch {
            showToast(.failure, "Couldn’t attach “\(name)” — \(error.localizedDescription)")
            return false
        }
    }

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
    /// (absolute paths are honoured too). A relative link that is not found
    /// under the primary folder is also tried under the secondary folder; when
    /// it exists nowhere, the primary location is reported (that is where the
    /// "not found" message should point).
    public func linkedDocumentURL(for transactionID: GncGUID) -> URL? {
        guard let link = book?.transaction(with: transactionID)?.documentLink else { return nil }
        if link.hasPrefix("file://") {
            return URL(string: link)
        }
        // GnuCash writes `assoc_uri` percent-encoded ("Cba%20atm.png"), so the
        // decoded form is the primary interpretation; the raw string stays as a
        // fallback for plain paths we stored ourselves (or names that really
        // contain a literal "%").
        var candidates: [String] = []
        if let decoded = link.removingPercentEncoding, decoded != link {
            candidates.append(decoded)
        }
        candidates.append(link)

        if link.hasPrefix("/") {
            for candidate in candidates
            where Self.fileIsPresentOrInCloud(URL(fileURLWithPath: candidate)) {
                return URL(fileURLWithPath: candidate)
            }
            return URL(fileURLWithPath: candidates[0])
        }
        for folder in [effectiveDocumentFolder, secondaryDocumentFolder].compactMap({ $0 }) {
            for candidate in candidates {
                let url = folder.appendingPathComponent(candidate)
                if Self.fileIsPresentOrInCloud(url) { return url }
            }
        }
        return effectiveDocumentFolder?.appendingPathComponent(candidates[0])
    }

    public func hasLinkedDocument(_ transactionID: GncGUID) -> Bool {
        book?.transaction(with: transactionID)?.documentLink != nil
    }

    /// The raw stored link (relative path, absolute path, or URL), if any.
    public func documentLink(for transactionID: GncGUID) -> String? {
        book?.transaction(with: transactionID)?.documentLink
    }

    /// Stores `link` verbatim (`nil` removes the association). One undoable
    /// action; the file itself is never touched.
    public func setDocumentLink(_ link: String?, for transactionID: GncGUID) {
        guard let book, let txn = book.transaction(with: transactionID),
              txn.documentLink != link else { return }
        editing([transactionID], named: link == nil ? "Remove Document Link" : "Set Document Link") {
            txn.documentLink = link
        }
    }

    /// Links an existing file **in place** — no copy, unlike
    /// ``attachDocument(named:data:to:)``. Stored relative to the document
    /// folder when the file lives inside it (so book + documents move
    /// together), else as an absolute path.
    public func linkDocument(at url: URL, to transactionID: GncGUID) {
        let path = url.standardizedFileURL.path
        var link = path
        if let base = effectiveDocumentFolder?.standardizedFileURL.path {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { link = String(path.dropFirst(prefix.count)) }
        }
        setDocumentLink(link, for: transactionID)
    }

    /// One transaction's document association, for the book-wide list
    /// (GnuCash's Tools ▸ Transaction Linked Documents).
    public struct LinkedDocument: Identifiable, Sendable {
        public let id: GncGUID
        public var date: Date
        public var description: String
        public var link: String
        /// The resolved file's name, or the raw link for a web URL.
        public var displayName: String
        public var isWeb: Bool
        /// `false` when a file link points at something no longer present.
        public var exists: Bool
    }

    /// Every transaction that carries a document link, newest first — the
    /// roll-up GnuCash offers so links aren't only reachable one register row
    /// at a time.
    public func linkedDocuments() -> [LinkedDocument] {
        guard let book else { return [] }
        return book.transactions.compactMap { txn -> LinkedDocument? in
            guard let link = txn.documentLink else { return nil }
            let isWeb = link.hasPrefix("http://") || link.hasPrefix("https://")
            let url = isWeb ? nil : linkedDocumentURL(for: txn.guid)
            return LinkedDocument(
                id: txn.guid,
                date: txn.datePosted,
                description: txn.transactionDescription,
                link: link,
                displayName: isWeb ? link : (url?.lastPathComponent ?? link),
                isWeb: isWeb,
                exists: isWeb ? true : (url.map { Self.fileIsPresentOrInCloud($0) } ?? false))
        }
        .sorted { $0.date > $1.date }
    }

    /// Opens the linked document in its default application (macOS). On iOS
    /// the attachments panel offers Quick Look instead — this reports that
    /// rather than silently doing nothing (F22).
    public func openLinkedDocument(for transactionID: GncGUID) {
        guard let url = linkedDocumentURL(for: transactionID) else { return }
        #if os(macOS)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            infoMessage = "The linked document “\(url.lastPathComponent)” was not found in \(url.deletingLastPathComponent().path)."
        }
        #else
        showToast(.info, "Use Quick Look to view attachments on this device.")
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
