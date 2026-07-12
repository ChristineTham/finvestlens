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
}

/// An application-level advisory lock guarding a document on shared storage
/// (Architecture §6.1).
///
/// Because SQLite's own locking is unreliable over SMB/NFS, FinvestLens enforces
/// single-writer access with a sibling `<document>.lock` file carrying holder
/// metadata and a heartbeat. A lock whose heartbeat has gone stale (holder
/// crashed) can be broken. Creation uses an atomic "write-if-absent" so two
/// machines cannot both acquire.
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

    public init(
        documentURL: URL,
        heartbeatInterval: TimeInterval = 25,
        staleAfter: TimeInterval = 90
    ) {
        self.documentURL = documentURL
        self.lockURL = URL(fileURLWithPath: documentURL.path + ".lock")
        self.heartbeatInterval = heartbeatInterval
        self.staleAfter = staleAfter
    }

    /// `true` if this instance currently holds the lock.
    public var isHeldByUs: Bool { held }

    /// The current holder, or `nil` if the lock file is absent/unreadable.
    public func currentHolder() -> LockHolder? {
        guard let data = try? Data(contentsOf: lockURL) else { return nil }
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
            try data.write(to: lockURL, options: [.withoutOverwriting])
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
        try? FileManager.default.removeItem(at: lockURL)
        try acquire(now: now)
    }

    /// Refreshes the heartbeat timestamp; must be called by the holder.
    public func refreshHeartbeat(now: Date = Date()) throws {
        guard held else { throw LockError.notHeldByUs }
        let holder = makeHolder(now: now)
        let data = try JSONEncoder().encode(holder)
        try data.write(to: lockURL, options: [.atomic])
    }

    /// Releases the lock if we hold it (removes the lock file).
    public func release() {
        guard held else { return }
        if let holder = currentHolder(), holder.instanceID == instanceID {
            try? FileManager.default.removeItem(at: lockURL)
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
