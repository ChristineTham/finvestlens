//
//  ReportNarrator.swift
//  FinvestLens — Intelligence
//
//  Commentary for a financial report (`FR-AI-06`), on the ForecastNarrator
//  model: the figures are computed deterministically by the Reports engine and
//  handed over as facts — the model observes, it never calculates. An annual
//  report's notes point at what moved and what dominates; that is a language
//  task over numbers already known, which is the one kind of arithmetic a
//  language model can be trusted with.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The numbers a report commentary is written from.
public struct ReportFacts: Sendable {
    public var reportTitle: String
    public var periodLabel: String
    public var currencyCode: String
    /// Headline figures, label → amount, in display order.
    public var headline: [(String, Decimal)]
    /// The largest line items, label → amount, already ranked by the report.
    public var lines: [(String, Decimal)]

    public init(reportTitle: String, periodLabel: String, currencyCode: String,
                headline: [(String, Decimal)], lines: [(String, Decimal)]) {
        self.reportTitle = reportTitle
        self.periodLabel = periodLabel
        self.currencyCode = currencyCode
        self.headline = headline
        self.lines = lines
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Turns a computed report into two-to-four short observations.
@available(macOS 26.0, iOS 26.0, *)
public enum ReportNarrator {

    @Generable
    struct ModelNotes {
        @Guide(description: "Two to four short observations grounded ONLY in the given figures — what dominates, what the relationship between the headline numbers is. No advice, no speculation, no invented numbers.")
        var notes: [String]
    }

    public static func narrate(facts: ReportFacts) async throws -> [String] {
        guard IntelligenceAvailability.current().isAvailable else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }

        let headline = facts.headline
            .map { "- \($0.0): \($0.1) \(facts.currencyCode)" }
            .joined(separator: "\n")
        let lines = facts.lines.prefix(12)
            .map { "- \($0.0): \($0.1) \(facts.currencyCode)" }
            .joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You write brief notes for the reports section of a personal finance \
            app, in the tone of an annual report's commentary. Use only the \
            figures provided — never invent or recompute numbers. Be concrete \
            and calm; no financial advice, no recommendations.
            """)
        do {
            let model = try await session.respond(
                to: """
                    Report: \(facts.reportTitle)
                    Period: \(facts.periodLabel)
                    Headline figures:
                    \(headline)
                    Largest line items:
                    \(lines.isEmpty ? "(none)" : lines)
                    """,
                generating: ModelNotes.self
            ).content
            // The guide asks for two-to-four notes, but the model does not
            // always honour the ceiling; enforce it so the section stays tight.
            return Array(model.notes.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(4))
        } catch {
            throw IntelligenceError.wrap(error)
        }
    }
}
#endif
