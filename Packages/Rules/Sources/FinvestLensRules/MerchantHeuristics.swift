//
//  MerchantHeuristics.swift
//  FinvestLens — Rules
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Cleans raw bank-statement descriptions and maps them to a default category
/// name, for auto-categorisation on import (`FR-RULE-03`, Frollo-inspired).
public enum MerchantHeuristics {

    /// A tidy merchant name from a raw statement line, e.g.
    /// `"WOOLWORTHS 1234 SYDNEY AU  CARD 5678"` → `"Woolworths"`.
    public static func cleanMerchant(_ raw: String) -> String {
        var text = raw.uppercased()

        // Drop common transaction prefixes.
        for prefix in ["EFTPOS ", "VISA ", "MASTERCARD ", "POS ", "DEBIT ", "PURCHASE ", "PAYMENT ", "DIRECT DEBIT "] {
            if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        }
        // Cut at card / reference markers.
        for marker in [" CARD ", " XX", " REF ", " RECEIPT ", " AUS", "  "] {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }

        // Keep leading word-ish tokens, stopping at the first that is mostly digits
        // or a known trailing location/country code.
        let stopWords: Set<String> = ["AU", "AUS", "USA", "US", "NSW", "VIC", "QLD", "WA", "SA", "TAS", "ACT", "NT"]
        var kept: [String] = []
        for token in text.split(separator: " ").map(String.init) {
            let digitCount = token.filter(\.isNumber).count
            if digitCount * 2 >= token.count { break }        // mostly digits → stop
            if stopWords.contains(token) { break }
            kept.append(token)
            if kept.count >= 3 { break }
        }
        let cleaned = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return titleCase(cleaned.isEmpty ? text.trimmingCharacters(in: .whitespaces) : cleaned)
    }

    /// The default category name for a description, by keyword, or `nil`.
    public static func category(for description: String) -> String? {
        let haystack = description.lowercased()
        for (keywords, category) in keywordCategories {
            if keywords.contains(where: { haystack.contains($0) }) { return category }
        }
        return nil
    }

    private static func titleCase(_ text: String) -> String {
        text.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Keyword → default category. Ordered; first match wins.
    static let keywordCategories: [(keywords: [String], category: String)] = [
        (["woolworths", "coles", "aldi", "iga", "grocer", "supermarket"], "Groceries"),
        (["mcdonald", "kfc", "cafe", "coffee", "restaurant", "uber eats", "doordash", "menulog"], "Dining"),
        (["shell", "bp ", "caltex", "ampol", "petrol", "fuel", "7-eleven"], "Fuel"),
        (["uber", "lyft", "taxi", "opal", "myki", "transport", "metro"], "Transport"),
        (["netflix", "spotify", "disney", "prime video", "youtube premium"], "Subscriptions"),
        (["telstra", "optus", "vodafone", "internet", "broadband", "mobile"], "Phone & Internet"),
        (["origin energy", "agl", "energy", "electricity", "water", "gas bill"], "Utilities"),
        (["chemist", "pharmacy", "medical", "doctor", "dental", "hospital"], "Health"),
        (["rent", "landlord", "real estate"], "Rent"),
        (["salary", "payroll", "wages"], "Salary"),
        (["interest"], "Interest"),
        (["kmart", "target", "big w", "amazon", "ebay"], "Shopping"),
        (["gym", "fitness", "cinema", "ticketek"], "Entertainment"),
        (["insurance"], "Insurance"),
    ]
}
