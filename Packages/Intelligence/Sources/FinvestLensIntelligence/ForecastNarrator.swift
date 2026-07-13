//
//  ForecastNarrator.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The numeric facts a forecast narrative is written from. All values are
/// computed deterministically from the book and scheduled transactions —
/// the model narrates, it never predicts numbers.
public struct ForecastFacts: Sendable {
    public var currencyCode: String
    public var accountName: String
    public var horizonDays: Int
    public var openingBalance: Decimal
    public var closingBalance: Decimal
    public var lowestBalance: Decimal
    public var lowestBalanceDate: Date?
    /// (date, label, amount) of upcoming scheduled cash movements.
    public var upcoming: [(Date, String, Decimal)]
    /// Average monthly net income over recent history.
    public var recentMonthlyNet: Decimal

    public init(currencyCode: String, accountName: String, horizonDays: Int,
                openingBalance: Decimal, closingBalance: Decimal,
                lowestBalance: Decimal, lowestBalanceDate: Date?,
                upcoming: [(Date, String, Decimal)], recentMonthlyNet: Decimal) {
        self.currencyCode = currencyCode
        self.accountName = accountName
        self.horizonDays = horizonDays
        self.openingBalance = openingBalance
        self.closingBalance = closingBalance
        self.lowestBalance = lowestBalance
        self.lowestBalanceDate = lowestBalanceDate
        self.upcoming = upcoming
        self.recentMonthlyNet = recentMonthlyNet
    }
}

/// A short cash-flow outlook for display alongside the forecast chart.
public struct ForecastInsights: Sendable {
    public let headline: String
    public let insights: [String]
}

#if canImport(FoundationModels)
import FoundationModels

/// Turns a computed cash-flow forecast into a plain-language outlook
/// (`FR-AI-06`): a one-line headline plus a few observations — tight months,
/// large upcoming bills, savings headroom.
@available(macOS 26.0, iOS 26.0, *)
public enum ForecastNarrator {

    @Generable
    struct ModelOutlook {
        @Guide(description: "One-sentence headline verdict on the cash position")
        var headline: String
        @Guide(description: "Two to four short, specific observations grounded ONLY in the given numbers")
        var insights: [String]
    }

    public static func narrate(facts: ForecastFacts) async throws -> ForecastInsights {
        guard IntelligenceAvailability.current().isAvailable else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        let lowest = facts.lowestBalanceDate.map { " on \(formatter.string(from: $0))" } ?? ""
        let upcoming = facts.upcoming.prefix(12).map {
            "- \(formatter.string(from: $0.0)): \($0.1) (\($0.2))"
        }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You write short, factual cash-flow outlooks for a personal finance app. \
            Use only the numbers provided — never invent figures. Be concrete and \
            calm; no financial advice, no recommendations to buy or sell anything.
            """)
        do {
            let model = try await session.respond(
                to: """
                    Account: \(facts.accountName) (\(facts.currencyCode))
                    Forecast horizon: \(facts.horizonDays) days
                    Balance today: \(facts.openingBalance)
                    Projected balance at end: \(facts.closingBalance)
                    Lowest projected balance: \(facts.lowestBalance)\(lowest)
                    Average monthly net income recently: \(facts.recentMonthlyNet)
                    Scheduled movements:
                    \(upcoming.isEmpty ? "(none)" : upcoming)
                    """,
                generating: ModelOutlook.self
            ).content
            return ForecastInsights(headline: model.headline, insights: model.insights)
        } catch {
            throw IntelligenceError.wrap(error)
        }
    }
}
#endif
