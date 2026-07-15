//
//  SearchNoticeTests.swift
//  FinvestLens — FeatureUI
//
//  Telling the user when the query did something they didn't ask for.
//
//  `date:2026` looks like an operator and isn't one, so it is searched as
//  literal text and finds nothing. The search was never wrong — it was silent,
//  and silence is the bug: the results pane only appeared when there were
//  results, so a query that matched nothing dropped you back on the dashboard
//  with no sign it had run.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@MainActor
@Suite("Search notices")
struct SearchNoticeTests {

    private func book() throws -> (AppModel, URL) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "CDIA", type: .bank))
        let expense = try #require(model.addAccount(name: "Motor", type: .expense))
        // Taken verbatim from the reference book: a description that really
        // does contain "Date:".
        _ = model.addTransfer(from: bank, to: expense, amount: dec("5"),
                              date: Date(timeIntervalSince1970: 1_700_000_000),
                              description: "NRMA LTD SYDNEY OLYMPI NS AUS Card xx6838 Value Date: 09/04/2026")
        return (model, url)
    }

    @Test("An unknown key is reported, not swallowed")
    func unknownKeyIsReported() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.searchQuery = "date:2026"

        #expect(model.searchResults.isEmpty)
        #expect(model.searchNotices == [.unknownKey("date")])
        #expect(model.isSearching, "the results pane must still appear to say 'no results'")
    }

    /// The reason this is a notice and not an error. "Value Date: 09/04/2026" is
    /// real text in the book, so `Date:` has to keep working as a literal
    /// search — refusing the query would break a search that legitimately finds
    /// something.
    @Test("An unknown key still searches as literal text")
    func unknownKeyStillSearchesLiterally() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.searchQuery = "Date:"

        #expect(model.searchResults.count == 1, "the literal search must still run")
        #expect(model.searchNotices == [.unknownKey("date")], "and must still say what it did")
    }

    @Test("Known keys are silent")
    func knownKeysAreSilent() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        for query in ["account:CDIA", "desc:NRMA", "memo:x", "amount:>1", "tag:foo", "acct:CDIA"] {
            model.searchQuery = query
            #expect(model.searchNotices.isEmpty, "\(query) is a real operator")
        }
    }

    @Test("Plain text is not mistaken for a key")
    func plainTextIsSilent() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.searchQuery = "NRMA"
        #expect(model.searchNotices.isEmpty)
        #expect(model.searchResults.count == 1)
    }

    /// A time like `09:30` or an account number is not someone reaching for an
    /// operator, and must not be nagged about.
    @Test("A non-alphabetic prefix is not a key")
    func numericPrefixIsNotAKey() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.searchQuery = "09:30"
        #expect(model.searchNotices.isEmpty)
    }

    @Test("Each unknown key is named once")
    func unknownKeysAreDeduplicated() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.searchQuery = "date:2026 date:2025 notes:x"
        #expect(model.searchNotices == [.unknownKey("date"), .unknownKey("notes")])
    }

    @Test("Clearing the query clears the notices")
    func clearingQueryClearsNotices() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.searchQuery = "date:2026"
        #expect(!model.searchNotices.isEmpty)

        model.searchQuery = ""
        #expect(model.searchNotices.isEmpty)
        #expect(!model.isSearching)
    }
}
