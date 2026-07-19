//
//  Serialize.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import OSLog
import FinvestLensEngine

/// Warnings for non-canonical persisted data. The store's own writer never
/// produces these, so a hit means a corrupt or externally-edited file — the
/// resilient fallback still returns a value, but it's no longer silent.
let persistenceLog = Logger(subsystem: "com.hellotham.finvestlens", category: "persistence")

/// Conversions between engine value types and their SQLite column encodings.
enum Serialize {

    // MARK: Commodity namespace

    static func namespace(_ namespace: CommodityNamespace) -> String {
        switch namespace {
        case .currency: return "CURRENCY"
        case .security(let name): return "SECURITY:\(name)"
        case .other(let name): return "OTHER:\(name)"
        }
    }

    static func parseNamespace(_ raw: String) -> CommodityNamespace {
        if raw == "CURRENCY" { return .currency }
        if let range = raw.range(of: "SECURITY:") { return .security(String(raw[range.upperBound...])) }
        if let range = raw.range(of: "OTHER:") { return .other(String(raw[range.upperBound...])) }
        return .other(raw)
    }

    static func commodityKey(_ commodity: Commodity) -> String {
        "\(namespace(commodity.namespace))|\(commodity.mnemonic)"
    }

    // MARK: Decimal (exact, locale-independent text)

    static func decimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }

    static func parseDecimal(_ text: String) -> Decimal {
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            persistenceLog.warning("Unparseable decimal \"\(text, privacy: .public)\" defaulted to 0")
            return 0
        }
        return value
    }

    // MARK: KVP frame (JSON, nil when empty)

    static func kvp(_ frame: KvpFrame) -> String? {
        guard !frame.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(frame) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseKvp(_ text: String?) -> KvpFrame {
        guard let text else { return KvpFrame() }
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(KvpFrame.self, from: data)
        else {
            persistenceLog.warning("Unparseable KVP frame discarded; preserved GnuCash slots may be lost")
            return KvpFrame()
        }
        return frame
    }
}
