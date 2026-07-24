//
//  Kvp.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A typed value in a ``KvpFrame`` "slot".
///
/// Covers the GnuCash KVP slot types. `numeric` values are represented with
/// `Decimal` (consistent with ``Money``). Slots — including keys FinvestLens
/// does not model — are preserved on import and re-emitted on export to keep
/// GnuCash round-trips lossless (Architecture ADR-4).
public indirect enum KvpValue: Hashable, Codable, Sendable {
    case int64(Int64)
    case double(Double)
    case numeric(Decimal)
    case string(String)
    case guid(GncGUID)
    /// A day-only date (GnuCash `gdate`), or a date-time that happens to be
    /// representable either way — exports as `gdate` when at midnight.
    case date(Date)
    /// A date-time that must stay a GnuCash `timespec` on export even at
    /// exactly midnight — the round-trip distinction `date` cannot carry.
    case timespec(Date)
    case frame(KvpFrame)
    case list([KvpValue])
}

/// A recursively-nested dictionary of ``KvpValue`` "slots" attached to an
/// engine object, mirroring GnuCash's key-value frames.
public struct KvpFrame: Hashable, Codable, Sendable {

    /// The slots keyed by name. Nested frames model GnuCash's `/`-delimited paths.
    public var slots: [String: KvpValue]

    public init(_ slots: [String: KvpValue] = [:]) {
        self.slots = slots
    }

    /// `true` when there are no slots.
    public var isEmpty: Bool { slots.isEmpty }

    public subscript(key: String) -> KvpValue? {
        get { slots[key] }
        set { slots[key] = newValue }
    }
}
