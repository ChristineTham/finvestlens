//
//  QIFImport.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Parses Quicken Interchange Format (QIF) files (`FR-XIO-01`).
///
/// QIF is line-oriented: a single-letter code begins each line, records end
/// with `^`, and `!Type:` headers introduce sections. Hand-written per
/// Architecture §5.8a (no Swift package exists).
public enum QIFImporter {

    /// Common QIF date encodings, tried in order. `''` is a literal apostrophe.
    static let dateFormats = [
        "MM/dd/yyyy", "M/d/yyyy", "dd/MM/yyyy", "d/M/yyyy",
        "MM/dd''yy", "M/d''yy", "yyyy-MM-dd",
    ]

    public static func parse(_ data: Data) -> [StagedTransaction] {
        parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) -> [StagedTransaction] {
        var result: [StagedTransaction] = []
        var investing = false        // inside a !Type:Invst section
        var date: Date?
        var amount: Decimal?
        var payee = "", memo = "", reference = "", category = ""
        // Investment-record fields (`!Type:Invst`).
        var action = "", security = ""
        var quantity: Decimal?, price: Decimal?, commission: Decimal?
        // Split legs (`S`/`E`/`$`), accumulated per record.
        var splits: [StagedSplit] = []
        var splitCategory: String?, splitMemo = "", splitAmount: Decimal?

        func closeSplit() {
            if let splitCategory {
                splits.append(StagedSplit(category: splitCategory,
                                          amount: splitAmount ?? 0, memo: splitMemo))
            }
            splitCategory = nil; splitMemo = ""; splitAmount = nil
        }

        func flush() {
            closeSplit()
            defer {
                date = nil; amount = nil; payee = ""; memo = ""; reference = ""; category = ""
                action = ""; security = ""; quantity = nil; price = nil; commission = nil
                splits = []; splitCategory = nil; splitMemo = ""
            }
            guard let date else { return }
            if investing, !action.isEmpty {
                // A security record: derive the cash amount when the file omits
                // it (T/U) but gives quantity × price.
                let mapped = investmentAction(action)
                let qty = quantity ?? 0, unit = price ?? 0
                // Commission adds to a buy's cash outlay but reduces a sell's net
                // proceeds; derive the row total accordingly when T/U is omitted.
                let fee = commission ?? 0
                let cash = amount ?? ((qty * unit) + (mapped == .sell ? -fee : fee))
                result.append(StagedTransaction(
                    date: date, amount: cash, payee: security, memo: memo,
                    reference: action, category: category,
                    investment: InvestmentDetail(action: mapped, security: security,
                                                 quantity: qty, pricePerShare: unit,
                                                 commission: commission ?? 0)))
            } else if let amount {
                result.append(StagedTransaction(date: date, amount: amount, payee: payee,
                                                memo: memo, reference: reference, category: category,
                                                splits: splits.filter { $0.amount != 0 }))
            }
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let code = line.first else { continue }
            let value = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            switch code {
            case "!":                                   // section header
                investing = value.lowercased().contains("invst")
            case "^": flush()
            case "D": date = parseDate(value)
            case "T", "U": amount = ImportParsing.amount(value)
            case "M": memo = value
            case "L": category = value
            // `N` is the payee cheque-number for cash, but the *action* in an
            // investment record; `Y`/`I`/`Q`/`O` only appear in investment ones.
            case "N": if investing { action = value } else { reference = value }
            case "P": payee = value
            case "Y": security = value
            case "I": price = ImportParsing.amount(value)
            case "Q": quantity = ImportParsing.amount(value)
            case "O": commission = ImportParsing.amount(value)
            // Split legs: `S` opens a new one (closing the previous), `E` is its
            // memo, `$` its amount.
            case "S": closeSplit(); splitCategory = value
            case "E": splitMemo = value
            case "$": splitAmount = ImportParsing.amount(value)
            default: break
            }
        }
        flush()                                          // trailing record without ^
        return result
    }

    /// Maps a QIF investment action code to a normalised ``InvestmentDetail``.
    static func investmentAction(_ raw: String) -> InvestmentDetail.Action {
        switch raw.lowercased() {
        case "buy", "buyx", "shrsin", "cvtshrt": return .buy
        case "sell", "sellx", "shrsout": return .sell
        case "reinvdiv", "reinvlg", "reinvsh", "reinvint", "reinvmd": return .reinvestDividend
        case "div", "divx", "cgshort", "cgshortx", "cglong", "cglongx",
             "intinc", "intincx", "miscinc", "miscincx", "rtrncap", "rtrncapx":
            return .dividend
        default: return .other
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let text = raw.replacingOccurrences(of: " ", with: "")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
