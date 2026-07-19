//
//  APIKeyStore.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(Security)
import Security
#endif

/// Stores per-provider API keys. The app never handles keys in plaintext at
/// rest — the production implementation is the system Keychain (`FR-SEC-01`).
public protocol APIKeyStoring: Sendable {
    /// The stored key for `kind`, or `nil` if none is set.
    func key(for kind: QuoteProviderKind) -> String?
    /// Stores `key` for `kind`, or removes it when `key` is `nil`/empty.
    func setKey(_ key: String?, for kind: QuoteProviderKind) throws
}

/// In-memory key store for tests and SwiftUI previews.
public final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [QuoteProviderKind: String] = [:]

    public init(_ initial: [QuoteProviderKind: String] = [:]) {
        storage = initial
    }

    public func key(for kind: QuoteProviderKind) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[kind]
    }

    public func setKey(_ key: String?, for kind: QuoteProviderKind) throws {
        lock.lock(); defer { lock.unlock() }
        if let key, !key.isEmpty {
            storage[kind] = key
        } else {
            storage[kind] = nil
        }
    }
}

#if canImport(Security)
/// Keychain-backed key store (generic password items).
public struct KeychainAPIKeyStore: APIKeyStoring {
    private let service: String

    public init(service: String = "com.hellotham.finvestlens.quotes") {
        self.service = service
    }

    public func key(for kind: QuoteProviderKind) -> String? {
        var query = baseQuery(for: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    public func setKey(_ key: String?, for kind: QuoteProviderKind) throws {
        let query = baseQuery(for: kind)
        SecItemDelete(query as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var insert = query
        insert[kSecValueData as String] = Data(key.utf8)
        // Device-bound: an API key must not ride an encrypted backup to another
        // device, and is never needed before first unlock.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw QuoteError.providerError("Keychain write failed (\(status))")
        }
    }

    private func baseQuery(for kind: QuoteProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
    }
}
#endif
