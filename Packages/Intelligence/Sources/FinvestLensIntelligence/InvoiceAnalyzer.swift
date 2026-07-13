//
//  InvoiceAnalyzer.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One line item read from an invoice, with an optional category suggestion.
public struct InvoiceLineItem: Sendable, Identifiable {
    public let id = UUID()
    public var itemDescription: String
    public var amount: Decimal
    public var suggestedCategoryID: GncGUID?

    public init(itemDescription: String, amount: Decimal, suggestedCategoryID: GncGUID? = nil) {
        self.itemDescription = itemDescription
        self.amount = amount
        self.suggestedCategoryID = suggestedCategoryID
    }
}

/// The analysed contents of an invoice PDF.
public struct InvoiceAnalysis: Sendable {
    public var vendor: String
    public var date: Date?
    public var total: Decimal
    public var lineItems: [InvoiceLineItem]

    public init(vendor: String, date: Date?, total: Decimal, lineItems: [InvoiceLineItem]) {
        self.vendor = vendor
        self.date = date
        self.total = total
        self.lineItems = lineItems
    }

    /// Sum of line items — compare with `total` to surface OCR/extraction
    /// discrepancies in review UI rather than silently posting them.
    public var lineItemSum: Decimal {
        lineItems.reduce(0) { $0 + $1.amount }
    }
}

/// Reads an invoice PDF and proposes an expense split per line item
/// (`FR-AI-03`), so one card charge can be recorded against the accounts it
/// actually covers.
@available(macOS 26.0, iOS 26.0, *)
public enum InvoiceAnalyzer {

    #if canImport(FoundationModels)
    @Generable
    struct ModelLineItem {
        @Guide(description: "What was purchased, short")
        var item: String
        @Guide(description: "The line's total price, the amount printed at the end of that same line — a positive number unless the line is a discount or refund")
        var amount: String
    }

    @Generable
    struct ModelInvoice {
        @Guide(description: "Vendor or store name")
        var vendor: String
        @Guide(description: "Invoice date in yyyy-MM-dd format, empty if not shown")
        var date: String
        @Guide(description: "Grand total of the invoice as printed")
        var total: String
        @Guide(description: "Every billed line item — one entry per printed line, never merged. Exclude subtotal, tax-only, and total rows; keep discounts as negative amounts.")
        var lineItems: [ModelLineItem]
    }
    #endif

    /// Extracts vendor, date, total, and line items, then categorises each
    /// line item against `candidates` (pass expense accounts).
    public static func analyze(
        text: String,
        candidates: [CategoryCandidate]
    ) async throws -> InvoiceAnalysis {
        #if canImport(FoundationModels)
        guard IntelligenceAvailability.current().isAvailable else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }

        let session = LanguageModelSession(instructions: """
            You read invoices and receipts. Extract the vendor, date, grand total, \
            and each billed line item exactly as printed. Each printed line is one \
            line item — never merge adjacent lines, and take each item's amount \
            from the end of its own line. The line items should add up to the \
            grand total. Never invent line items.
            """)
        let invoice: ModelInvoice
        do {
            invoice = try await session.respond(
                to: "Invoice text:\n\n\(String(text.prefix(6000)))",
                generating: ModelInvoice.self,
                options: GenerationOptions(sampling: .greedy)
            ).content
        } catch {
            throw IntelligenceError.wrap(error)
        }

        var items: [InvoiceLineItem] = invoice.lineItems.compactMap { line in
            guard let amount = IntelligenceParsing.amount(line.amount), amount != 0 else { return nil }
            return InvoiceLineItem(itemDescription: line.item, amount: amount)
        }

        // Sign reconciliation: the model occasionally emits stray minus signs.
        // When the printed grand total matches the sum of absolute values (but
        // not the signed sum), the signs were wrong — real discounts keep the
        // signed sum equal to the total, so they are left untouched.
        if let total = IntelligenceParsing.amount(invoice.total), total > 0 {
            let signedSum = items.reduce(Decimal(0)) { $0 + $1.amount }
            let absoluteSum = items.reduce(Decimal(0)) { $0 + abs($1.amount) }
            if signedSum != total, absoluteSum == total {
                for index in items.indices {
                    items[index].amount = abs(items[index].amount)
                }
            }
        }

        // Second pass: map each line item onto the book's expense accounts.
        if !candidates.isEmpty, !items.isEmpty {
            let categorizables = items.map {
                CategorizationItem(id: $0.id, payee: $0.itemDescription, amount: -$0.amount)
            }
            let suggestions = try await TransactionCategorizer.suggest(
                items: categorizables, candidates: candidates
            )
            for index in items.indices {
                items[index].suggestedCategoryID = suggestions[items[index].id]
            }
        }

        return InvoiceAnalysis(
            vendor: invoice.vendor,
            date: IntelligenceParsing.date(invoice.date),
            total: IntelligenceParsing.amount(invoice.total) ?? items.reduce(0) { $0 + $1.amount },
            lineItems: items
        )
        #else
        throw IntelligenceError.unavailable("Apple Intelligence is not available on this platform.")
        #endif
    }
}
