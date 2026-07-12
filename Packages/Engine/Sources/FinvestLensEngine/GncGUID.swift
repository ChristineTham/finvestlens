//
//  GncGUID.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A 128-bit identifier compatible with GnuCash's GUID format.
///
/// GnuCash serialises GUIDs as **32 lowercase hexadecimal characters with no
/// dashes** — *not* RFC-4122 formatting (Architecture ADR-3). Imported GUIDs
/// must round-trip byte-for-byte, so this type owns its own hex codec and never
/// relies on `Foundation.UUID`'s dashed/uppercase string form.
public struct GncGUID: Hashable, Sendable, CustomStringConvertible {

    /// The 16 raw bytes, most-significant first.
    public let bytes: [UInt8]

    /// Creates a GUID from exactly 16 bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// Parses a 32-character hex string (dashes are tolerated on input and
    /// stripped, but canonical output never contains them).
    public init?(hex rawInput: String) {
        let hex = rawInput.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self.bytes = out
    }

    /// The canonical 32-character lowercase hex string (no dashes).
    public var hexString: String {
        bytes.reduce(into: "") { $0 += String(format: "%02x", $1) }
    }

    public var description: String { hexString }

    /// Generates a random GUID from the system CSPRNG.
    public static func random() -> GncGUID {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        // Force-unwrap is safe: exactly 16 bytes were produced.
        return GncGUID(bytes: bytes)!
    }
}

extension GncGUID: Identifiable {
    /// A GUID is its own identity.
    public var id: GncGUID { self }
}

// MARK: - Codable (as the canonical hex string)

extension GncGUID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let guid = GncGUID(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid GnuCash GUID hex string: \(hex)"
            )
        }
        self = guid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}
