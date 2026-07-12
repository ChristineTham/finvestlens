//
//  GnuCashNumeric.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Parses GnuCash's rational amount strings (`"num/denom"`, e.g. `"10000/100"`)
/// into `Decimal`.
///
/// GnuCash stores every amount as an exact rational. FinvestLens uses `Decimal`
/// (Architecture ADR-1), so we divide numerator by denominator — accepting the
/// rounding that implies for non-terminating fractions.
enum GnuCashNumeric {

    /// Parses `"num/denom"` (or a bare integer) into a `Decimal`. Returns `nil`
    /// for malformed input or a zero denominator.
    static func parse(_ raw: String) -> Decimal? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        guard let slash = text.firstIndex(of: "/") else {
            return Decimal(string: text)
        }
        let numeratorText = String(text[text.startIndex..<slash])
        let denominatorText = String(text[text.index(after: slash)...])

        guard let numerator = Decimal(string: numeratorText),
              let denominator = Decimal(string: denominatorText),
              denominator != 0
        else { return nil }

        return numerator / denominator
    }
}
