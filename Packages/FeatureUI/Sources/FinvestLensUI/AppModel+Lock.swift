//
//  AppModel+Lock.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Device authentication, injectable so tests/previews never trigger a real
/// biometric prompt (`NFR-07`).
public protocol Authenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

/// Face/Touch ID (or device password) via LocalAuthentication. Where no auth is
/// configured on the device, it succeeds so the user is never locked out.
public struct BiometricAuthenticator: Authenticating {
    public init() {}
    public func authenticate(reason: String) async -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        #else
        return true
        #endif
    }
}

/// Always-succeeds authenticator for tests and previews.
public struct AllowAllAuthenticator: Authenticating {
    public init() {}
    public func authenticate(reason: String) async -> Bool { true }
}

@MainActor
extension AppModel {

    /// Whether this book requires Face/Touch ID (or the device password) to open
    /// (`NFR-07`). Persisted in the book KVP.
    public var requireAuthentication: Bool {
        get {
            if case let .int64(v)? = book?.kvp["finvestlens/requireAuth"] { return v != 0 }
            return false
        }
        set {
            editingBookKvp(named: "Change Authentication Setting") {
                book?.kvp["finvestlens/requireAuth"] = .int64(newValue ? 1 : 0)
            }
        }
    }

    /// Locks the book if it requires authentication (called after open).
    func lockIfNeeded() {
        isLocked = requireAuthentication
    }

    /// Locks the open book immediately.
    public func lockNow() {
        guard isOpen else { return }
        isLocked = true
    }

    /// Attempts to unlock via device biometrics/password. Returns `true` on
    /// success (and always succeeds where LocalAuthentication is unavailable, so
    /// tests and headless builds aren't blocked).
    @discardableResult
    public func unlock(reason: String = "Unlock your book") async -> Bool {
        let ok = await authenticator.authenticate(reason: reason)
        if ok { isLocked = false }
        return ok
    }
}
