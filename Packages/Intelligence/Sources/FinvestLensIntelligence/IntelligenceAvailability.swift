//
//  IntelligenceAvailability.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple Intelligence features can run on this device, and if not, why.
///
/// The on-device model requires macOS 26 / iOS 26 on Apple silicon with
/// Apple Intelligence enabled in System Settings. Callers use this to hide or
/// disable AI features rather than surfacing errors after the fact.
public enum IntelligenceAvailability: Sendable, Equatable {
    case available
    /// A short, user-presentable explanation (device, OS, or setting).
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }

    /// Probes the system model. Cheap enough to call whenever a menu is built.
    public static func current() -> IntelligenceAvailability {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            return .unavailable(reason: "Apple Intelligence requires macOS 26 or iOS 26.")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This device does not support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Turn on Apple Intelligence in System Settings to use this feature.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "The Apple Intelligence model is still downloading. Try again shortly.")
        case .unavailable:
            return .unavailable(reason: "Apple Intelligence is not available on this device.")
        }
        #else
        return .unavailable(reason: "Apple Intelligence is not available on this platform.")
        #endif
    }
}

/// Errors surfaced by Intelligence features.
public enum IntelligenceError: LocalizedError {
    case unavailable(String)
    case emptyDocument
    case guardrailDeclined
    case modelFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyDocument:
            return "No readable text was found in the document."
        case .guardrailDeclined:
            return "Apple Intelligence declined to process this content (safety guardrails). Enter the details manually instead."
        case .modelFailure(let detail):
            return "Apple Intelligence could not process this request: \(detail)"
        }
    }

    /// Wraps a FoundationModels error, keeping IntelligenceErrors as-is and
    /// translating guardrail refusals into an actionable message.
    static func wrap(_ error: any Error) -> IntelligenceError {
        if let error = error as? IntelligenceError { return error }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *),
           let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation, .refusal:
                return .guardrailDeclined
            default:
                break
            }
        }
        #endif
        return .modelFailure(error.localizedDescription)
    }
}
