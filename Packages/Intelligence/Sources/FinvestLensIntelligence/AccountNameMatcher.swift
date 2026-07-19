//
//  AccountNameMatcher.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A category account offered to the model as a categorisation target.
///
/// Value type so it can cross actor boundaries — Intelligence never holds
/// Engine reference types.
public struct CategoryCandidate: Sendable, Hashable, Identifiable {
    public let id: GncGUID
    /// Colon-delimited full name, e.g. `Expenses:Food:Groceries`.
    public let fullName: String

    public init(id: GncGUID, fullName: String) {
        self.id = id
        self.fullName = fullName
    }

    var leafName: String {
        fullName.components(separatedBy: ":").last ?? fullName
    }
}

/// Maps a model-generated category name back to a real account.
///
/// The on-device model is prompted with the exact candidate names, but its
/// output is free text — so resolution is deterministic and forgiving:
/// exact full name, then exact leaf name, then path suffix, then substring.
public enum AccountNameMatcher {

    public static func match(_ name: String, in candidates: [CategoryCandidate]) -> CategoryCandidate? {
        let needle = normalize(name)
        guard !needle.isEmpty else { return nil }

        if let hit = candidates.first(where: { normalize($0.fullName) == needle }) {
            return hit
        }
        if let hit = candidates.first(where: { normalize($0.leafName) == needle }) {
            return hit
        }
        // "Food:Groceries" matching "Expenses:Food:Groceries".
        if let hit = candidates.first(where: { normalize($0.fullName).hasSuffix(":" + needle) }) {
            return hit
        }
        // Last leaf component of the model's answer, e.g. "Expenses > Dining".
        let lastComponent = normalize(name.components(separatedBy: CharacterSet(charactersIn: ":>/")).last ?? "")
        if !lastComponent.isEmpty, lastComponent != needle {
            if let hit = candidates.first(where: { normalize($0.leafName) == lastComponent }) {
                return hit
            }
        }
        // Substring either way, longest candidate name first for specificity.
        let bySpecificity = candidates.sorted { $0.fullName.count > $1.fullName.count }
        return bySpecificity.first {
            let candidate = normalize($0.leafName)
            // Account-leaf contains the model's answer, or vice versa — but only
            // when the shorter side is long enough that the containment is
            // meaningful, so a 3-letter leaf like "Tax" doesn't swallow "Taxi".
            if candidate.contains(needle) { return true }
            return candidate.count >= 4 && needle.contains(candidate)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .filter { $0.isLetter || $0.isNumber || $0 == ":" }
    }
}
