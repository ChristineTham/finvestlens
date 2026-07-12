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
    }

    /// The shared document location (may be on a NAS / iCloud).
    public let fileURL: URL
    /// The in-memory book (source of truth while open).
    public private(set) var book: Book
    /// Whether there are unsaved changes.
    public var hasUnsavedChanges: Bool

    private let lock: FileLock
    private let workingCopyURL: URL
    private var store: SQLiteDocumentStore
    /// Hash of the shared file as of open / last successful save — for conflict
    /// detection (`FR-DAT-08`).
    private var baselineFingerprint: Data

    private init(fileURL: URL, book: Book, lock: FileLock,
                 workingCopyURL: URL, store: SQLiteDocumentStore,
                 fingerprint: Data, dirty: Bool) {
        self.fileURL = fileURL
        self.book = book
        self.lock = lock
        self.workingCopyURL = workingCopyURL
        self.store = store
        self.baselineFingerprint = fingerprint
        self.hasUnsavedChanges = dirty
    }

    // MARK: Open / create

    /// Creates a new, empty document at `fileURL` and opens it.
    public static func create(at fileURL: URL, baseCurrency: Commodity = .aud) throws -> FinvestLensDocument {
        let lock = FileLock(documentURL: fileURL)
        try lock.acquire()

        let workingCopyURL = Self.makeWorkingCopyURL()
        let store = try SQLiteDocumentStore(path: workingCopyURL.path)
        let book = Book(baseCurrency: baseCurrency)
        try store.write(book)
        try Self.copyItem(from: workingCopyURL, to: fileURL)

        let fingerprint = try Self.fingerprint(of: fileURL)
        return FinvestLensDocument(fileURL: fileURL, book: book, lock: lock,
                                   workingCopyURL: workingCopyURL, store: store,
                                   fingerprint: fingerprint, dirty: false)
    }

    /// Opens an existing document: acquires the lock, copies it to a local
    /// working copy, and materialises the book.
    public static func open(at fileURL: URL, breakStaleLock: Bool = false) throws -> FinvestLensDocument {
        let lock = FileLock(documentURL: fileURL)
        do {
            try lock.acquire()
        } catch FileLock.LockError.alreadyLocked where breakStaleLock {
            try lock.breakStaleLockAndAcquire()
        }

        let workingCopyURL = Self.makeWorkingCopyURL()
        try Self.copyItem(from: fileURL, to: workingCopyURL)
        let store = try SQLiteDocumentStore(path: workingCopyURL.path)
        let book = try store.read()
        let fingerprint = try Self.fingerprint(of: fileURL)

        return FinvestLensDocument(fileURL: fileURL, book: book, lock: lock,
                                   workingCopyURL: workingCopyURL, store: store,
                                   fingerprint: fingerprint, dirty: false)
    }

    // MARK: Editing

    /// Marks the in-memory book as modified (call after mutating ``book``).
    public func markDirty() { hasUnsavedChanges = true }

    // MARK: Save / discard

    /// Writes the working copy back to the shared file, atomically and under the
    /// lock, after verifying the shared file has not changed beneath us.
    public func save() throws {
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
        try? lock.refreshHeartbeat()
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
    public func heartbeat() { try? lock.refreshHeartbeat() }

    // MARK: File helpers

    private static func makeWorkingCopyURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinvestLens-working", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString + ".finvestlens")
    }

    private static func copyItem(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
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
        let data = try Data(contentsOf: url)
        return Data(SHA256.hash(data: data))
    }
}
