//
//  AmountInWords.swift
//  FinvestLens — Engine
//
//  Spelling a money amount out in English words for the "amount in words" line
//  of a printed check (GnuCash's Tools ▸ Print Check, `numeric_to_words`). The
//  integer part is written in words; the fractional part is a "NN/100" fraction,
//  as banks require.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Renders a decimal money amount as the words a check's legal line carries —
/// e.g. `1234.50` → `"One thousand two hundred thirty-four and 50/100"`.
public enum AmountInWords {

    private static let ones = ["zero", "one", "two", "three", "four", "five",
                               "six", "seven", "eight", "nine", "ten", "eleven",
                               "twelve", "thirteen", "fourteen", "fifteen",
                               "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty",
                               "sixty", "seventy", "eighty", "ninety"]
    /// Scale words for successive groups of three digits.
    private static let scales = ["", " thousand", " million", " billion", " trillion"]

    /// The English words for a whole number below one thousand (no leading
    /// "and"; "one hundred five", not "one hundred and five", matching US checks).
    private static func underThousand(_ n: Int) -> String {
        if n < 20 { return ones[n] }
        if n < 100 {
            let t = tens[n / 10]
            return n % 10 == 0 ? t : "\(t)-\(ones[n % 10])"
        }
        let hundreds = "\(ones[n / 100]) hundred"
        let rest = n % 100
        return rest == 0 ? hundreds : "\(hundreds) \(underThousand(rest))"
    }

    /// The English words for a non-negative whole number, grouped in thousands.
    static func words(forWholeNumber value: Int) -> String {
        guard value != 0 else { return "zero" }
        var groups: [Int] = []
        var remaining = value
        while remaining > 0 {
            groups.append(remaining % 1000)
            remaining /= 1000
        }
        var parts: [String] = []
        for index in stride(from: groups.count - 1, through: 0, by: -1) {
            let group = groups[index]
            guard group != 0 else { continue }
            parts.append(underThousand(group) + scales[index])
        }
        return parts.joined(separator: " ")
    }

    /// The check "legal amount" line for `amount` in a `fraction`-based currency
    /// (100 for dollars/cents). The whole part is spelled out and capitalised;
    /// the remainder is written as a fraction over the currency's minor unit —
    /// e.g. `"One thousand two hundred thirty-four and 50/100"`. Negative amounts
    /// use their magnitude (a check is never written for a negative sum).
    public static func english(_ amount: Decimal, fraction: Int = 100) -> String {
        let magnitude = amount < 0 ? -amount : amount
        let denom = max(1, fraction)
        // Whole units and remaining minor units, rounded to the minor unit.
        var rounded = Decimal()
        var scaled = magnitude * Decimal(denom)
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let totalMinor = NSDecimalNumber(decimal: rounded).intValue
        let whole = totalMinor / denom
        let minor = totalMinor % denom
        let digits = String(denom).count - 1        // 100 → 2 digits
        let fractionText = String(format: "%0\(max(1, digits))d/%d", minor, denom)
        let wholeWords = words(forWholeNumber: whole)
        return wholeWords.prefix(1).uppercased() + wholeWords.dropFirst() + " and \(fractionText)"
    }
}
