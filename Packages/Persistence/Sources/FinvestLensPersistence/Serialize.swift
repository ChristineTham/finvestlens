//
//  Serialize.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

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
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    // MARK: KVP frame (JSON, nil when empty)

    static func kvp(_ frame: KvpFrame) -> String? {
        guard !frame.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(frame) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseKvp(_ text: String?) -> KvpFrame {
        guard let text, let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(KvpFrame.self, from: data)
        else { return KvpFrame() }
        return frame
    }
}
