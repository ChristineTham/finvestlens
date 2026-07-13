//
//  DocumentClassifier.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What kind of financial document a PDF is, deciding how Smart Import
/// handles it (`FR-AI-07`).
public enum FinancialDocumentKind: String, Sendable, CaseIterable {
    case bankStatement = "bank statement"
    case dividendStatement = "dividend statement"
    case invoice = "invoice or receipt"
    case unknown = "something else"

    public var displayName: String {
        switch self {
        case .bankStatement: return "Bank statement"
        case .dividendStatement: return "Dividend statement"
        case .invoice: return "Invoice / receipt"
        case .unknown: return "Unrecognised"
        }
    }
}

/// Classifies a financial document from its extracted text.
///
/// The on-device model reads the opening of the document; a deterministic
/// keyword heuristic answers when the model is unavailable (or declines) and
/// serves as the tie-breaker for `unknown` answers — classification must
/// never be the step that fails a whole import batch.
public enum DocumentClassifier {

    /// Deterministic fallback. Order matters: a "dividend statement" contains
    /// the word "statement", so dividends are recognised first.
    public static func classifyByKeywords(_ text: String) -> FinancialDocumentKind {
        let lower = text.lowercased()
        func containsAny(_ needles: [String]) -> Bool {
            needles.contains { lower.contains($0) }
        }
        if containsAny(["dividend", "distribution statement", "franking", "franked"]) {
            return .dividendStatement
        }
        if containsAny(["tax invoice", "invoice", "receipt #", "receipt no"]) {
            return .invoice
        }
        if lower.contains("statement") || containsAny(["opening balance", "closing balance"]) {
            return .bankStatement
        }
        if containsAny(["total", "subtotal", "amount due", "gst"]) {
            return .invoice
        }
        return .unknown
    }

    /// Classifies with the on-device model, falling back to keywords.
    public static func classify(text: String) async -> FinancialDocumentKind {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *),
              IntelligenceAvailability.current().isAvailable
        else {
            return classifyByKeywords(text)
        }
        let session = LanguageModelSession(instructions: """
            You identify what kind of financial document a text is. Answer with \
            exactly one of: bank statement, dividend statement, invoice or \
            receipt, something else. A bank or credit card statement lists many \
            dated transactions with a balance. A dividend statement reports a \
            single dividend or distribution payment. An invoice or receipt \
            bills line items with a total.
            """)
        do {
            let answer = try await session.respond(
                to: "Document:\n\n\(String(text.prefix(1500)))\n\nWhat kind of document is this?",
                generating: ModelKind.self,
                options: GenerationOptions(sampling: .greedy)
            ).content
            let kind = FinancialDocumentKind(rawValue: answer.kind.lowercased()) ?? .unknown
            return kind == .unknown ? classifyByKeywords(text) : kind
        } catch {
            return classifyByKeywords(text)
        }
        #else
        return classifyByKeywords(text)
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    @Generable
    struct ModelKind {
        @Guide(description: "The document kind", .anyOf([
            "bank statement", "dividend statement", "invoice or receipt", "something else",
        ]))
        var kind: String
    }
    #endif
}
