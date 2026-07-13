//
//  FileLock.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Metadata about who holds a document lock.
public struct LockHolder: Codable, Equatable, Sendable {
    public var host: String
    public var user: String
    public var instanceID: String
    public var pid: Int32
    public var acquiredAt: Date
    public var heartbeatAt: Date

    public init(host: String, user: String, instanceID: String, pid: Int32,
                acquiredAt: Date, heartbeatAt: Date) {
        self.host = host
        self.user = user
        self.instanceID = instanceID
        self.pid = pid
        self.acquiredAt = acquiredAt
        self.heartbeatAt = heartbeatAt
    }
}

/// Declares the sibling lock file as a *related item* of the document, so a
/// sandboxed app's user-selected access to `Book.finvestlens` extends to
/// `Book.lock` (the app also declares the `lock` extension with
/// `NSIsRelatedItemType` in its Info.plist).
private final class LockFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    #if os(macOS)
    // Unavailable on iOS, where documents live in the app container and no
    // related-item grant is needed.
    let primaryPresentedItemURL: URL?
    #endif
    let presentedItemOperationQueue = OperationQueue()

    init(lockURL: URL, documentURL: URL) {
        self.presentedItemURL = lockURL
        #if os(macOS)
        self.primaryPresentedItemURL = documentURL
        #endif
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }
}

/// An application-level advisory lock guarding a document on shared storage
/// (Architecture §6.1).
///
/// Because SQLite's own locking is unreliable over SMB/NFS, FinvestLens enforces
/// single-writer access with a sibling `<document>.lock` file carrying holder
/// metadata and a heartbeat. A lock whose heartbeat has gone stale (holder
/// crashed) can be broken. Creation uses an atomic "write-if-absent" so two
/// machines cannot both acquire.
///
/// All lock-file I/O goes through `NSFileCoordinator` with a related-item
/// presenter, which is what lets a sandboxed app touch the sibling file at a
/// user-selected location.
public final class FileLock {

    public enum LockError: Error, Equatable {
        case alreadyLocked(LockHolder)
        case notHeldByUs
    }

    /// The document being guarded.
    public let documentURL: URL
    /// The sibling lock file URL.
    public let lockURL: URL

    /// How often the holder should refresh the heartbeat.
    public let heartbeatInterval: TimeInterval
    /// A lock is considered stale after this long without a heartbeat.
    public let staleAfter: TimeInterval

    private let instanceID = UUID().uuidString
    private var held = false
    private let presenter: LockFilePresenter

    public init(
        documentURL: URL,
        heartbeatInterval: TimeInterval = 25,
        staleAfter: TimeInterval = 90
    ) {
        self.documentURL = documentURL
        // Same base name, different extension ("Book.finvestlens" →
        // "Book.lock") — required for the sandbox related-item grant.
        self.lockURL = documentURL.deletingPathExtension().appendingPathExtension("lock")
        self.heartbeatInterval = heartbeatInterval
        self.staleAfter = staleAfter
        self.presenter = LockFilePresenter(lockURL: lockURL, documentURL: documentURL)
        NSFileCoordinator.addFilePresenter(presenter)
    }

    deinit {
        NSFileCoordinator.removeFilePresenter(presenter)
    }

    /// `true` if this instance currently holds the lock.
    public var isHeldByUs: Bool { held }

    // MARK: Coordinated lock-file I/O

    private func coordinatedRead() -> Data? {
        var data: Data?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: presenter)
            .coordinate(readingItemAt: lockURL, options: [.withoutChanges],
                        error: &coordError) { url in
                data = try? Data(contentsOf: url)
            }
        return data
    }

    private func coordinatedWrite(options: NSFileCoordinator.WritingOptions,
                                  _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: presenter)
            .coordinate(writingItemAt: lockURL, options: options,
                        error: &coordError) { url in
                do { try body(url) } catch { bodyError = error }
            }
        if let bodyError { throw bodyError }
        if let coordError { throw coordError }
    }

    /// The current holder, or `nil` if the lock file is absent/unreadable.
    public func currentHolder() -> LockHolder? {
        guard let data = coordinatedRead() else { return nil }
        return try? JSONDecoder().decode(LockHolder.self, from: data)
    }

    /// `true` if a lock exists but its heartbeat has aged past ``staleAfter``.
    public func isStale(now: Date = Date()) -> Bool {
        guard let holder = currentHolder() else { return false }
        return now.timeIntervalSince(holder.heartbeatAt) > staleAfter
    }

    /// Acquires the lock, throwing ``LockError/alreadyLocked(_:)`` if another
    /// live holder has it.
    public func acquire(now: Date = Date()) throws {
        let holder = makeHolder(now: now)
        let data = try JSONEncoder().encode(holder)
        do {
            // Atomic create-if-absent: fails if the file already exists.
            try coordinatedWrite(options: []) { url in
                try data.write(to: url, options: [.withoutOverwriting])
            }
            held = true
        } catch {
            if let existing = currentHolder() {
                throw LockError.alreadyLocked(existing)
            }
            throw error
        }
    }

    /// Breaks a stale lock and acquires it. Throws if the existing lock is
    /// **not** stale (a live holder).
    public func breakStaleLockAndAcquire(now: Date = Date()) throws {
        if let holder = currentHolder(), now.timeIntervalSince(holder.heartbeatAt) <= staleAfter {
            throw LockError.alreadyLocked(holder)
        }
        try? coordinatedWrite(options: [.forDeleting]) { url in
            try FileManager.default.removeItem(at: url)
        }
        try acquire(now: now)
    }

    /// Refreshes the heartbeat timestamp; must be called by the holder.
    public func refreshHeartbeat(now: Date = Date()) throws {
        guard held else { throw LockError.notHeldByUs }
        let holder = makeHolder(now: now)
        let data = try JSONEncoder().encode(holder)
        try coordinatedWrite(options: [.forReplacing]) { url in
            try data.write(to: url, options: [.atomic])
        }
    }

    /// Releases the lock if we hold it (removes the lock file).
    public func release() {
        guard held else { return }
        if let holder = currentHolder(), holder.instanceID == instanceID {
            try? coordinatedWrite(options: [.forDeleting]) { url in
                try FileManager.default.removeItem(at: url)
            }
        }
        held = false
    }

    private func makeHolder(now: Date) -> LockHolder {
        LockHolder(
            host: ProcessInfo.processInfo.hostName,
            user: NSUserName(),
            instanceID: instanceID,
            pid: ProcessInfo.processInfo.processIdentifier,
            acquiredAt: now,
            heartbeatAt: now
        )
    }
}
