//
//  FinvestLensDocument.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CryptoKit
import FinvestLensEngine

/// The executor that materialises books, off the main actor.
///
/// Reading a book is CPU-bound work over a reference graph that is deliberately
/// **not** `Sendable` (`Book` is a cyclic graph of classes; making it `Sendable`
/// would mean locking every access on the hot path). A global actor gives that
/// work a home off the main thread without changing the graph: the document is
/// built here, then handed to the caller as a `sending` value — the compiler
/// checks the freshly-built graph is unreachable from this actor, so exactly one
/// isolation domain can see it at a time.
@globalActor
public actor DocumentLoader {
    public static let shared = DocumentLoader()
}

/// A `.finvestlens` document with the check-out / edit-locally / explicit-save
/// lifecycle (Architecture §3 & §6.2).
///
/// On `open`, the document is locked and copied to a **local working copy**;
/// the in-memory ``Book`` is the source of truth during the session. The shared
/// file changes **only** on an explicit ``save()`` (or autosave), which performs
/// a coordinated atomic write-back with conflict detection. ``discard()`` throws
/// the working session away, leaving the shared file at the last save.
public final class FinvestLensDocument {

    public enum DocumentError: Error, Equatable {
        case conflict          // the shared file changed underneath us
        case alreadyOpen
        case readOnly          // opened read-only (someone else holds the lock)
    }

    /// True when the book was opened **read-only** (`FR-DAT-06`): no lock was
    /// acquired and ``save()`` is refused. Used when another instance holds a
    /// live lock and the user chooses to look without editing.
    public private(set) var isReadOnly = false

    /// The shared document location (may be on a NAS / iCloud).
    public let fileURL: URL
    /// The in-memory book (source of truth while open).
    public private(set) var book: Book
    /// What the load had to default (open-what-you-can, NFR-05) — surfaced
    /// as a warning toast by the app layer.
    public var loadWarnings: LoadWarnings? { store.lastLoadWarnings }
    /// Whether there are unsaved changes.
    public var hasUnsavedChanges: Bool

    private let lock: FileLock
    /// `false` when the sibling `.lock` file could not be created — e.g. an
    /// iOS file-provider location (iCloud Drive, Box, Dropbox) where the
    /// picker grant covers only the document itself. The document still
    /// opens; saves are guarded by fingerprint conflict detection instead.
    public private(set) var advisoryLockHeld: Bool
    private let workingCopyURL: URL
    private var store: SQLiteDocumentStore
    /// Hash of the shared file as of open / last successful save — for conflict
    /// detection (`FR-DAT-08`).
    private var baselineFingerprint: Data

    private init(fileURL: URL, book: Book, lock: FileLock, lockHeld: Bool,
                 workingCopyURL: URL, store: SQLiteDocumentStore,
                 fingerprint: Data, dirty: Bool) {
        self.fileURL = fileURL
        self.book = book
        self.lock = lock
        self.advisoryLockHeld = lockHeld
        self.workingCopyURL = workingCopyURL
        self.store = store
        self.baselineFingerprint = fingerprint
        self.hasUnsavedChanges = dirty
    }

    /// Acquires the advisory lock, tolerating environments where the lock
    /// file cannot be written. A **live** lock held by someone else still
    /// throws (`alreadyLocked`) — only "can't create the sibling file here"
    /// degrades to lockless mode.
    private static func acquireLockIfPossible(_ lock: FileLock,
                                              breakStaleLock: Bool) throws -> Bool {
        do {
            try lock.acquire()
            return true
        } catch let error as FileLock.LockError {
            if case .alreadyLocked = error, breakStaleLock {
                try lock.breakStaleLockAndAcquire()
                return true
            }
            throw error
        } catch {
            return false
        }
    }

    // MARK: Open / create

    /// Creates a new, empty document at `fileURL` and opens it.
    ///
    /// The document file is written *before* the lock is acquired: in a
    /// sandboxed app the sibling `.lock` file is reachable only through the
    /// related-item grant, which needs the primary document to exist.
    public static func create(at fileURL: URL, baseCurrency: Commodity = .aud) throws -> FinvestLensDocument {
        let workingCopyURL = Self.makeWorkingCopyURL()
        let store = try SQLiteDocumentStore(path: workingCopyURL.path)
        let book = Book(baseCurrency: baseCurrency)
        try store.write(book)
        try Self.replaceItem(at: fileURL, withContentsOf: workingCopyURL)

        let lock = FileLock(documentURL: fileURL)
        let lockHeld: Bool
        do {
            lockHeld = try Self.acquireLockIfPossible(lock, breakStaleLock: false)
        } catch {
            // A live lock on a file we just created — don't leave an
            // unlockable orphan behind.
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        let fingerprint = try Self.fingerprint(of: fileURL)
        return FinvestLensDocument(fileURL: fileURL, book: book, lock: lock,
                                   lockHeld: lockHeld,
                                   workingCopyURL: workingCopyURL, store: store,
                                   fingerprint: fingerprint, dirty: false)
    }

    /// Opens an existing document: acquires the lock, copies it to a local
    /// working copy, and materialises the book.
    ///
    /// `progress` reports the book read, which is ~95% of an open — the lock,
    /// the working copy (an APFS clone, effectively free) and the fingerprint
    /// are the rest. Omit it and nothing is metered.
    public static func open(at fileURL: URL, breakStaleLock: Bool = false,
                            progress: (@Sendable (BookLoadProgress) -> Void)? = nil) throws -> FinvestLensDocument {
        let lock = FileLock(documentURL: fileURL)
        let lockHeld = try Self.acquireLockIfPossible(lock, breakStaleLock: breakStaleLock)

        let workingCopyURL = Self.makeWorkingCopyURL()
        do {
            try Self.copyItem(from: fileURL, to: workingCopyURL)
        } catch {
            if lockHeld { lock.release() }
            throw error
        }
        let store = try SQLiteDocumentStore(path: workingCopyURL.path)
        let book = try store.read(progress: progress)
        let fingerprint = try Self.fingerprint(of: fileURL)

        return FinvestLensDocument(fileURL: fileURL, book: book, lock: lock,
                                   lockHeld: lockHeld,
                                   workingCopyURL: workingCopyURL, store: store,
                                   fingerprint: fingerprint, dirty: false)
    }

    /// Opens an existing document **read-only** (`FR-DAT-06`): reads it into a
    /// working copy and materialises the book **without acquiring the lock**, so
    /// it is safe to open while another instance holds a live lock. ``save()``
    /// is refused; the shared file is never touched.
    public static func openReadOnly(at fileURL: URL,
                                    progress: (@Sendable (BookLoadProgress) -> Void)? = nil) throws -> FinvestLensDocument {
        let lock = FileLock(documentURL: fileURL)     // constructed but never acquired
        let workingCopyURL = Self.makeWorkingCopyURL()
        try Self.copyItem(from: fileURL, to: workingCopyURL)
        let store = try SQLiteDocumentStore(path: workingCopyURL.path)
        let book = try store.read(progress: progress)
        let fingerprint = try Self.fingerprint(of: fileURL)

        let document = FinvestLensDocument(fileURL: fileURL, book: book, lock: lock,
                                           lockHeld: false,
                                           workingCopyURL: workingCopyURL, store: store,
                                           fingerprint: fingerprint, dirty: false)
        document.isReadOnly = true
        return document
    }

    /// ``openReadOnly(at:)`` performed off the main actor.
    @DocumentLoader
    public static func loadReadOnly(at fileURL: URL,
                                    progress: (@Sendable (BookLoadProgress) -> Void)? = nil) throws -> sending FinvestLensDocument {
        try openReadOnly(at: fileURL, progress: progress)
    }

    /// ``open(at:breakStaleLock:)`` performed off the main actor.
    ///
    /// This is how the app opens a book: materialising the reference book takes
    /// seconds on a large file, and on the main actor that time is a frozen,
    /// unrepainting window. The result is `sending`, so the built document
    /// leaves this actor entirely rather than being shared with it.
    @DocumentLoader
    public static func load(at fileURL: URL,
                            breakStaleLock: Bool = false,
                            progress: (@Sendable (BookLoadProgress) -> Void)? = nil) throws -> sending FinvestLensDocument {
        try open(at: fileURL, breakStaleLock: breakStaleLock, progress: progress)
    }

    // MARK: Editing

    /// Marks the in-memory book as modified (call after mutating ``book``).
    public func markDirty() { hasUnsavedChanges = true }

    /// Swaps in a different in-memory book (undo/redo snapshot restore).
    public func replaceBook(_ newBook: Book) {
        book = newBook
        markDirty()
    }

    // MARK: Save / discard

    /// Writes the working copy back to the shared file, atomically and under the
    /// lock, after verifying the shared file has not changed beneath us.
    public func save() throws {
        // A read-only session never touches the shared file (FR-DAT-06).
        if isReadOnly { throw DocumentError.readOnly }
        // Detect an out-of-band change to the shared file (bypassed lock, etc.).
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let current = try Self.fingerprint(of: fileURL)
            if current != baselineFingerprint {
                throw DocumentError.conflict
            }
        }

        try store.write(book)                                   // in-memory → working copy
        try Self.replaceItem(at: fileURL, withContentsOf: workingCopyURL)  // atomic write-back
        baselineFingerprint = try Self.fingerprint(of: fileURL)
        hasUnsavedChanges = false
        if advisoryLockHeld { try? lock.refreshHeartbeat() }
    }

    /// Discards unsaved changes by reloading the book from the shared file.
    /// The shared file is untouched.
    public func revert() throws {
        try Self.copyItem(from: fileURL, to: workingCopyURL)
        store = try SQLiteDocumentStore(path: workingCopyURL.path)
        book = try store.read()
        baselineFingerprint = try Self.fingerprint(of: fileURL)
        hasUnsavedChanges = false
    }

    /// Closes the document, discarding any unsaved working-session changes and
    /// releasing the lock. The shared file reflects only the last ``save()``.
    public func discard() {
        lock.release()
        try? FileManager.default.removeItem(at: workingCopyURL)
    }

    /// Refreshes the lock heartbeat (drive from a timer while open).
    public func heartbeat() {
        guard advisoryLockHeld else { return }
        try? lock.refreshHeartbeat()
    }

    // MARK: External changes / sync (`FR-PLT-02`)

    private var presenter: DocumentPresenter?

    /// `true` if the shared file changed since open / last save — e.g. an
    /// external writer or an iCloud sync from another device.
    public func hasExternalChanges() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let current = try? Self.fingerprint(of: fileURL) else { return false }
        return current != baselineFingerprint
    }

    /// Reloads the book from the shared file, adopting external changes and
    /// discarding unsaved local edits (alias for ``revert()``).
    public func reloadFromDisk() throws { try revert() }

    /// Observes the shared file for external changes; `handler` fires (on an
    /// arbitrary queue) whenever the file changes underneath us. Guard with
    /// ``hasExternalChanges()`` to ignore our own writes.
    public func startObservingExternalChanges(_ handler: @escaping @Sendable () -> Void) {
        stopObservingExternalChanges()
        let presenter = DocumentPresenter(url: fileURL, onChange: handler)
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
    }

    /// Stops observing external changes.
    public func stopObservingExternalChanges() {
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
    }

    /// iCloud conflict versions of this document awaiting resolution.
    public func unresolvedConflictVersions() -> [NSFileVersion] {
        NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL) ?? []
    }

    /// Resolves conflicts by keeping the current on-disk version.
    public func resolveConflictsKeepingCurrent() throws {
        for version in unresolvedConflictVersions() { version.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: fileURL)
        baselineFingerprint = try Self.fingerprint(of: fileURL)
    }

    /// Adopts a specific conflict version as the file contents and reloads.
    public func adoptConflictVersion(_ version: NSFileVersion) throws {
        try version.replaceItem(at: fileURL)
        for other in unresolvedConflictVersions() { other.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: fileURL)
        try reloadFromDisk()
    }

    // MARK: File helpers

    private static func makeWorkingCopyURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinvestLens-working", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString + ".finvestlens")
    }

    /// Copies the shared file to a local destination under a coordinated
    /// read. Coordination is what makes cloud placeholders work: a dataless
    /// item on iCloud Drive or a File Provider drive (Box, Dropbox) is
    /// downloaded and materialised before the accessor runs.
    private static func copyItem(from source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(readingItemAt: source, options: [],
                               error: &coordinationError) { url in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    private static func replaceItem(at destination: URL, withContentsOf source: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing,
                               error: &coordinationError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: copyToTemp(source, near: url))
                } else {
                    try FileManager.default.copyItem(at: source, to: url)
                }
            } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    /// `replaceItemAt` consumes the replacement item, so hand it a throwaway copy.
    private static func copyToTemp(_ source: URL, near destination: URL) throws -> URL {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: source, to: temp)
        return temp
    }

    private static func fingerprint(of url: URL) throws -> Data {
        // Coordinated for the same reason as `copyItem` — never hash a
        // half-synced or dataless cloud file.
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        coordinator.coordinate(readingItemAt: url, options: [],
                               error: &coordinationError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordinationError { throw coordinationError }
        return Data(SHA256.hash(data: try result.get()))
    }
}

/// Bridges `NSFilePresenter` change notifications to a callback (`FR-PLT-02`).
final class DocumentPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    private let queue: OperationQueue
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.queue = queue
        super.init()
    }

    var presentedItemOperationQueue: OperationQueue { queue }

    func presentedItemDidChange() { onChange() }
}
