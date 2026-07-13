//
//  DividendExtractor.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The details read from a dividend / distribution statement.
///
/// Follows Australian dividend statements (franked/unfranked components and
/// franking credits) but degrades gracefully for other markets: unfranked-only
/// statements simply have zero franked amounts.
public struct DividendStatementDetails: Sendable {
    public var securityName: String
    public var ticker: String
    public var paymentDate: Date?
    /// Fully franked component of the dividend.
    public var frankedAmount: Decimal
    /// Unfranked component of the dividend.
    public var unfrankedAmount: Decimal
    /// Franking (imputation) credits attached — not part of the cash payment.
    public var frankingCredits: Decimal
    /// Cash actually paid to the shareholder.
    public var netPayment: Decimal

    public init(securityName: String = "", ticker: String = "", paymentDate: Date? = nil,
                frankedAmount: Decimal = 0, unfrankedAmount: Decimal = 0,
                frankingCredits: Decimal = 0, netPayment: Decimal = 0) {
        self.securityName = securityName
        self.ticker = ticker
        self.paymentDate = paymentDate
        self.frankedAmount = frankedAmount
        self.unfrankedAmount = unfrankedAmount
        self.frankingCredits = frankingCredits
        self.netPayment = netPayment
    }

    /// The statement's own arithmetic check: cash paid should equal the sum
    /// of the components. Surfaced in review UI when it doesn't.
    public var componentsMatchPayment: Bool {
        netPayment == 0 || frankedAmount + unfrankedAmount == netPayment
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Reads a dividend statement PDF into ``DividendStatementDetails``
/// (`FR-AI-04`), so franked/unfranked components and franking credits are
/// booked correctly instead of as one opaque deposit.
@available(macOS 26.0, iOS 26.0, *)
public enum DividendExtractor {

    @Generable
    struct ModelDividend {
        @Guide(description: "Company or fund name paying the dividend")
        var security: String
        @Guide(description: "ASX/stock ticker code if shown, else empty")
        var ticker: String
        @Guide(description: "Payment date in yyyy-MM-dd format, empty if not shown")
        var paymentDate: String
        @Guide(description: "Franked amount of the dividend, 0 if not shown")
        var frankedAmount: String
        @Guide(description: "Unfranked amount of the dividend, 0 if not shown")
        var unfrankedAmount: String
        @Guide(description: "Franking credits (imputation credits) attached, 0 if not shown")
        var frankingCredits: String
        @Guide(description: "Net cash payment to the shareholder (total paid)")
        var netPayment: String
    }

    public static func extract(text: String) async throws -> DividendStatementDetails {
        guard IntelligenceAvailability.current().isAvailable else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }

        let session = LanguageModelSession(instructions: """
            You read dividend and distribution statements from share registries. \
            Extract the amounts exactly as printed. Franking credits are listed \
            separately from the cash payment — never add them together.
            """)
        do {
            let model = try await session.respond(
                to: "Dividend statement:\n\n\(String(text.prefix(6000)))",
                generating: ModelDividend.self,
                options: GenerationOptions(sampling: .greedy)
            ).content
            return DividendStatementDetails(
                securityName: model.security,
                ticker: model.ticker.uppercased(),
                paymentDate: IntelligenceParsing.date(model.paymentDate),
                frankedAmount: IntelligenceParsing.amount(model.frankedAmount) ?? 0,
                unfrankedAmount: IntelligenceParsing.amount(model.unfrankedAmount) ?? 0,
                frankingCredits: IntelligenceParsing.amount(model.frankingCredits) ?? 0,
                netPayment: IntelligenceParsing.amount(model.netPayment) ?? 0
            )
        } catch {
            throw IntelligenceError.wrap(error)
        }
    }
}
#endif
