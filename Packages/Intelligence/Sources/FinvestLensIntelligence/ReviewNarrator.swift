//
//  ReviewNarrator.swift
//  FinvestLens — Intelligence
//
//  The Financial Review deck's voice (docs/report-redesign.md §3.3): each
//  slide computes a deterministic facts pack, and the on-device model turns
//  it into an investor-deck action title and a one-to-two-sentence insight.
//  The established contract holds: the model proposes from the given figures
//  only; deterministic code disposes — the deck always has a deterministic
//  headline to fall back to, so Apple Intelligence being off never leaves an
//  empty title.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The numbers one slide is about — everything the narrator may use.
public struct ReviewSlideFacts: Sendable {
    /// The slide's section label ("Spending", "Portfolio").
    public var kicker: String
    public var periodLabel: String
    public var currencyCode: String
    /// Headline figures, label → amount, display order.
    public var figures: [(String, Decimal)]
    /// Changes vs the prior period, label → signed percent (already ×100),
    /// where a comparison exists.
    public var deltaPercents: [(String, Decimal)]

    public init(kicker: String, periodLabel: String, currencyCode: String,
                figures: [(String, Decimal)], deltaPercents: [(String, Decimal)] = []) {
        self.kicker = kicker
        self.periodLabel = periodLabel
        self.currencyCode = currencyCode
        self.figures = figures
        self.deltaPercents = deltaPercents
    }
}

/// What the model writes for a slide.
public struct ReviewSlideStory: Sendable {
    public var headline: String
    public var insight: String

    public init(headline: String, insight: String) {
        self.headline = headline
        self.insight = insight
    }
}

/// The dispose half of "the model proposes; deterministic code disposes":
/// every numeric token in a story must round-match a listed figure (raw, or
/// scaled by k/m), a listed delta percent, or be a calendar year. A story
/// quoting any number not grounded in its facts is rejected — the caller
/// falls back to the deterministic headline.
public enum ReviewStoryValidator {

    public static func isGrounded(_ story: ReviewSlideStory,
                                  facts: ReviewSlideFacts) -> Bool {
        let text = story.headline + " " + story.insight
        var candidates: [Decimal] = []
        for (_, value) in facts.figures {
            let magnitude = abs(value)
            candidates.append(magnitude)
            candidates.append(magnitude / 1_000)
            candidates.append(magnitude / 1_000_000)
        }
        for (_, delta) in facts.deltaPercents {
            candidates.append(abs(delta))
        }
        // Numbers that are part of the slide's own words — the period label
        // ("FY 2025–26"), the kicker, the figure labels — are quotable text,
        // not figures.
        let exemptSource = ([facts.periodLabel, facts.kicker]
            + facts.figures.map(\.0) + facts.deltaPercents.map(\.0))
            .joined(separator: " ")
        let exempt = numericTokens(in: exemptSource)

        for token in numericTokens(in: text) {
            // Calendar years read as dates, not figures.
            if token.decimalPlaces == 0, token.value >= 1900, token.value <= 2100 {
                continue
            }
            if exempt.contains(where: {
                $0.value == token.value && $0.decimalPlaces == token.decimalPlaces
            }) {
                continue
            }
            let tolerance = halfUnit(at: token.decimalPlaces)
            let grounded = candidates.contains { abs($0 - token.value) <= tolerance }
            if !grounded { return false }
        }
        return true
    }

    struct Token { var value: Decimal; var decimalPlaces: Int }

    static func numericTokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            defer { current = "" }
            let cleaned = current.replacingOccurrences(of: ",", with: "")
            guard cleaned.contains(where: \.isNumber),
                  let value = Decimal(string: cleaned) else { return }
            let places = cleaned.contains(".")
                ? cleaned.split(separator: ".").last.map { $0.count } ?? 0
                : 0
            tokens.append(Token(value: abs(value), decimalPlaces: places))
        }
        for character in text {
            if character.isNumber || character == "." || character == "," {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Half of the last quoted decimal place, plus a hair for Decimal noise —
    /// "3.83" matches anything in 3.825…3.835.
    static func halfUnit(at places: Int) -> Decimal {
        var unit = Decimal(1)
        for _ in 0..<places { unit /= 10 }
        return unit / 2 + Decimal(string: "0.0001")!
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
public enum ReviewNarrator {

    @Generable
    struct ModelStory {
        @Guide(description: "An investor-deck action title of 5 to 12 words that states the slide's conclusion from the given figures — like 'Spending fell 8% as travel normalised'. State facts, never advice. Use only the given numbers; round naturally.")
        var headline: String
        @Guide(description: "One or two calm sentences of insight grounded ONLY in the given figures: what dominates, what changed versus the prior period, what the relationship between the numbers is. No advice, no speculation, no invented numbers.")
        var insight: String
    }

    public static func story(facts: ReviewSlideFacts) async throws -> ReviewSlideStory {
        guard IntelligenceAvailability.current().isAvailable else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }

        let figures = facts.figures
            .map { "- \($0.0): \($0.1) \(facts.currencyCode)" }
            .joined(separator: "\n")
        let deltas = facts.deltaPercents
            .map { "- \($0.0): \($0.1 >= 0 ? "+" : "")\($0.1)% vs prior period" }
            .joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You write one slide of a personal financial review, in the voice \
            of a CFO presenting results: factual, specific, calm. The title \
            states the slide's conclusion. Quote numbers ONLY as they appear \
            in the lists — you may round to at most one decimal place or \
            express thousands as k and millions as m. NEVER derive numbers \
            that are not listed: no differences, no ratios, no percentages \
            of your own. If no change figures are listed, do not mention \
            changes. Never advise.
            """)
        let prompt = """
            Slide section: \(facts.kicker)
            Period: \(facts.periodLabel)
            Figures:
            \(figures)
            \(deltas.isEmpty ? "" : "Changes:\n\(deltas)")
            """
        let response = try await session.respond(to: prompt, generating: ModelStory.self)
        let headline = response.content.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let insight = response.content.insight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty else {
            throw IntelligenceError.modelFailure("The model returned an empty headline.")
        }
        let story = ReviewSlideStory(headline: headline, insight: insight)
        guard ReviewStoryValidator.isGrounded(story, facts: facts) else {
            throw IntelligenceError.modelFailure(
                "The model quoted a number that is not in the slide's facts.")
        }
        return story
    }
}
#endif
