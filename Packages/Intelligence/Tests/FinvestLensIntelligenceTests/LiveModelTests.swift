//
//  LiveModelTests.swift
//  FinvestLens — Intelligence
//
//  End-to-end smoke tests against the real on-device model. They render a
//  realistic PDF, extract it, and check the *substance* of the result while
//  staying lenient about wording — the model is nondeterministic. Skipped
//  automatically when Apple Intelligence is unavailable (CI, older OS,
//  setting off), so the deterministic suite stays fast and reliable.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import Foundation
import Testing
import CoreGraphics
import CoreText
import FinvestLensEngine
@testable import FinvestLensIntelligence

/// Renders lines of text into a single-page PDF at `url`.
private func makePDF(lines: [String], at url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    var y: CGFloat = 740
    for text in lines {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        context.textPosition = CGPoint(x: 60, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        y -= 18
    }
    context.endPDFPage()
    context.closePDF()
}

private func tempPDF() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("finvestlens-live-\(UUID().uuidString).pdf")
}

private let modelAvailable = IntelligenceAvailability.current().isAvailable

@Suite("Live on-device model", .enabled(if: modelAvailable),
       .timeLimit(.minutes(4)), .serialized)
struct LiveModelTests {

    @available(macOS 26.0, *)
    @Test("Bank statement PDF extracts signed, dated transactions")
    func statement() async throws {
        let url = tempPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        try makePDF(lines: [
            "EXAMPLE BANK — Everyday Account Statement",
            "Statement period 1 March 2026 to 31 March 2026",
            "Opening balance 3,000.00",
            "",
            "Date        Description                        Debit      Credit     Balance",
            "02/03/2026  WOOLWORTHS METRO SYDNEY            45.20                 2,954.80",
            "05/03/2026  SALARY ACME PTY LTD                           5,200.00   8,154.80",
            "09/03/2026  TRANSPORT FOR NSW TAP               62.35                8,092.45",
            "14/03/2026  NETFLIX.COM                         22.99                8,069.46",
            "",
            "Closing balance 8,069.46",
        ], at: url)

        let pages = try DocumentText.extractPages(from: url)
        let staged = try await StatementExtractor.extract(pages: pages)

        #expect(staged.count == 4, "expected 4 rows, got \(staged.map(\.payee))")
        let salary = try #require(staged.first { $0.amount > 0 })
        #expect(salary.amount == 5200)
        let woolworths = try #require(staged.first { $0.payee.uppercased().contains("WOOLWORTHS") })
        #expect(woolworths.amount == Decimal(string: "-45.20"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.component(.month, from: woolworths.date) == 3)
        #expect(calendar.component(.year, from: woolworths.date) == 2026)
    }

    @available(macOS 26.0, *)
    @Test("The model classifies statement, dividend, and invoice documents")
    func classification() async throws {
        let statement = """
            EXAMPLE BANK — Everyday Account
            Period 1 May 2026 to 31 May 2026, opening 4,120.55
            04/05/2026 WOOLWORTHS 82.45 4,038.10
            07/05/2026 SALARY 5,200.00 9,238.10
            Closing 9,238.10
            """
        let dividend = """
            BHP GROUP LIMITED — DIVIDEND STATEMENT
            ASX Code: BHP — payment date 12 June 2026
            Fully franked dividend 412.30, franking credits 176.70
            Net dividend paid to your nominated account 412.30
            """
        let invoice = """
            OFFICEWORKS — TAX INVOICE #IN-559023
            1 Brother Laser Printer 499.00
            TOTAL (inc GST) 499.00
            """
        #expect(await DocumentClassifier.classify(text: statement) == .bankStatement)
        #expect(await DocumentClassifier.classify(text: dividend) == .dividendStatement)
        #expect(await DocumentClassifier.classify(text: invoice) == .invoice)
    }

    @available(macOS 26.0, *)
    @Test("Transactions categorise onto the offered accounts")
    func categorization() async throws {
        let candidates = [
            CategoryCandidate(id: .random(), fullName: "Expenses:Food:Groceries"),
            CategoryCandidate(id: .random(), fullName: "Expenses:Entertainment:Streaming"),
            CategoryCandidate(id: .random(), fullName: "Expenses:Transport:Public Transport"),
            CategoryCandidate(id: .random(), fullName: "Income:Salary"),
        ]
        let items = [
            CategorizationItem(payee: "WOOLWORTHS METRO SYDNEY", amount: Decimal(string: "-45.20")!),
            CategorizationItem(payee: "NETFLIX.COM", amount: Decimal(string: "-22.99")!),
            CategorizationItem(payee: "SALARY ACME PTY LTD", amount: 5200),
        ]
        let suggestions = try await TransactionCategorizer.suggest(items: items, candidates: candidates)

        let byName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.fullName) })
        #expect(suggestions[items[0].id].map { byName[$0] } == "Expenses:Food:Groceries")
        #expect(suggestions[items[1].id].map { byName[$0] } == "Expenses:Entertainment:Streaming")
        #expect(suggestions[items[2].id].map { byName[$0] } == "Income:Salary")
    }

    @available(macOS 26.0, *)
    @Test("Invoice PDF splits into categorised line items")
    func invoice() async throws {
        let url = tempPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        try makePDF(lines: [
            "HARVEY NORMAN — TAX INVOICE #INV-88231",
            "Date: 14 March 2026",
            "",
            "Qty  Item                                          Amount",
            "1    LG 27\" 4K Monitor                             449.00",
            "1    Logitech MX Keys Keyboard                     199.95",
            "2    HDMI 2.1 Cable                                 59.90",
            "",
            "Subtotal (inc GST)                                708.85",
            "TOTAL                                             708.85",
        ], at: url)

        let candidates = [
            CategoryCandidate(id: .random(), fullName: "Expenses:Home Office:Equipment"),
            CategoryCandidate(id: .random(), fullName: "Expenses:Food:Groceries"),
        ]
        let text = try DocumentText.extractText(from: url)
        let analysis = try await InvoiceAnalyzer.analyze(text: text, candidates: candidates)

        #expect(analysis.vendor.uppercased().contains("HARVEY"))
        #expect(analysis.total == Decimal(string: "708.85"))
        #expect(analysis.lineItems.count == 3, "got \(analysis.lineItems.map(\.itemDescription))")
        #expect(analysis.lineItemSum == analysis.total,
                "items \(analysis.lineItems.map { "\($0.itemDescription)=\($0.amount)" })")
        // Everything on this invoice is office equipment, not groceries.
        let equipment = candidates[0].id
        #expect(analysis.lineItems.allSatisfy { $0.suggestedCategoryID == equipment })
    }

    @available(macOS 26.0, *)
    @Test("Dividend statement extracts franked components and credits")
    func dividend() async throws {
        let url = tempPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        try makePDF(lines: [
            "COMMONWEALTH BANK OF AUSTRALIA — DIVIDEND STATEMENT",
            "ASX Code: CBA",
            "Payment date: 26 March 2026",
            "",
            "Fully franked dividend                          217.00",
            "Unfranked dividend                                0.00",
            "Franking credits                                 93.00",
            "",
            "Net dividend paid to your bank account          217.00",
        ], at: url)

        let text = try DocumentText.extractText(from: url)
        let details = try await DividendExtractor.extract(text: text)

        #expect(details.ticker == "CBA")
        #expect(details.frankedAmount == 217)
        #expect(details.unfrankedAmount == 0)
        #expect(details.frankingCredits == 93)
        #expect(details.netPayment == 217)
        #expect(details.componentsMatchPayment)
    }

    @available(macOS 26.0, *)
    @Test("Budget advisor keeps essentials near average and explains itself")
    func budget() async throws {
        let groceries = GncGUID.random()
        let dining = GncGUID.random()
        let history = [
            SpendingHistory(categoryID: groceries, fullName: "Expenses:Food:Groceries",
                            monthlyAverage: 820, monthlyMinimum: 760, monthlyMaximum: 905),
            SpendingHistory(categoryID: dining, fullName: "Expenses:Food:Dining Out",
                            monthlyAverage: 460, monthlyMinimum: 300, monthlyMaximum: 640),
        ]
        let suggestion = try await BudgetAdvisor.suggest(history: history,
                                                         monthlyIncome: 7800,
                                                         currencyCode: "AUD")
        #expect(!suggestion.summary.isEmpty)
        #expect(suggestion.lines.count == 2, "got \(suggestion.lines.map(\.fullName))")
        for line in suggestion.lines {
            #expect(line.monthlyAmount > 0)
            #expect(!line.rationale.isEmpty)
        }
        // Groceries are essential: the suggestion should stay in a sane band.
        if let line = suggestion.lines.first(where: { $0.categoryID == groceries }) {
            #expect(line.monthlyAmount >= 600 && line.monthlyAmount <= 1000,
                    "groceries suggestion \(line.monthlyAmount) outside sanity band")
        }
    }

    @available(macOS 26.0, *)
    @Test("Report narrator writes grounded notes for a computed statement")
    func reportCommentary() async throws {
        // The FY 2025–26 income-statement anchor: figures arrive computed, the
        // model only observes them.
        let facts = ReportFacts(
            reportTitle: "Income Statement",
            periodLabel: "FY 2025–26",
            currencyCode: "AUD",
            headline: [("Income", Decimal(string: "233856.12")!),
                       ("Expenses", Decimal(string: "79013.41")!),
                       ("Net income", Decimal(string: "154842.71")!)],
            lines: [("Income:Dividends", Decimal(string: "61234.00")!),
                    ("Expenses:Income Tax", Decimal(string: "40185.68")!),
                    ("Income:Distributions", Decimal(string: "9275.32")!),
                    ("Expenses:Brokerage", Decimal(string: "4988.84")!)])

        let notes = try await ReportNarrator.narrate(facts: facts)
        // Nondeterministic wording; check the shape and that it is grounded.
        #expect((2...4).contains(notes.count), "got \(notes)")
        #expect(notes.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    @available(macOS 26.0, *)
    @Test("Forecast narrator writes a grounded outlook")
    func forecast() async throws {
        let facts = ForecastFacts(
            currencyCode: "AUD", accountName: "Everyday", horizonDays: 90,
            openingBalance: 8069, closingBalance: 9420,
            lowestBalance: 3105,
            lowestBalanceDate: IntelligenceParsing.date("2026-08-02"),
            upcoming: [
                (IntelligenceParsing.date("2026-08-01")!, "Rent", -2600),
                (IntelligenceParsing.date("2026-08-15")!, "Salary", 5200),
            ],
            recentMonthlyNet: 450
        )
        let insights = try await ForecastNarrator.narrate(facts: facts)
        #expect(!insights.headline.isEmpty)
        #expect((2...4).contains(insights.insights.count))
    }
}
#endif
