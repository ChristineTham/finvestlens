//
//  GoToDateTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's Go to Date (⌘G). The register had ⌘↑/⌘↓ for the two ends and
//  nothing in between — on an account with 5,385 postings that is not
//  navigation. Date *filtering* existed, which is a different affordance:
//  hiding the rest is not the same as going somewhere.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Go to date")
struct GoToDateTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
    }

    /// Postings on days 0, 10 and 20 — the gaps are the point: most dates have
    /// nothing on them.
    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        for day in [0, 10, 20] {
            _ = try model.addTransaction(
                date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
                description: "day \(day)", currency: .aud,
                splits: [SplitInput(accountID: bank, value: 10),
                         SplitInput(accountID: income, value: -10)])
        }
        model.selectedAccountID = bank
        return Fixture(model: model, url: url, bank: bank)
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private func landedOn(_ f: Fixture) -> String? {
        guard let id = f.model.pendingRegisterSplitID else { return nil }
        return f.model.registerRows.first { $0.id == id }?.description
    }

    @Test("Landing on a date something happened lands on it")
    func exactDate() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(f.model.goToDate(day(10)))
        #expect(landedOn(f) == "day 10")
    }

    /// The case that makes this usable: most days have no posting, and a jump
    /// that only worked on days something happened would be a jump you could
    /// not use to look around.
    @Test("A date with nothing on it lands on the next posting")
    func nextPosting() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(f.model.goToDate(day(5)))
        #expect(landedOn(f) == "day 10")
    }

    /// A picked date carries whatever time the picker had; only the day counts.
    ///
    /// The two hours are deliberate. These fixtures post at midnight *UTC*,
    /// which is mid-morning in this machine's zone, so adding a large offset
    /// walks over local midnight and lands on the next day — correctly, and
    /// confusingly. Two hours stays inside the same local day wherever this
    /// runs east of UTC, which is the case being tested.
    @Test("A time of day on the right date still lands on that date")
    func timeOfDayIgnored() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let sameDay = day(10).addingTimeInterval(2 * 3600)
        #expect(Calendar.current.isDate(sameDay, inSameDayAs: day(10)))
        #expect(f.model.goToDate(sameDay))
        #expect(landedOn(f) == "day 10")
    }

    @Test("Before everything lands on the first posting")
    func beforeAll() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(f.model.goToDate(day(-100)))
        #expect(landedOn(f) == "day 0")
    }

    /// Nothing after the last posting is a question with no answer, not a reason
    /// to jump to the end — the sheet says so rather than dismissing onto an
    /// unchanged register, which would read as the jump being ignored.
    @Test("After everything goes nowhere, and says so")
    func afterAll() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(!f.model.goToDate(day(100)))
        #expect(f.model.pendingRegisterSplitID == nil)
    }

    @Test("An empty register goes nowhere")
    func emptyRegister() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.selectedAccountID = nil
        #expect(!f.model.goToDate(day(0)))
    }

    /// The jump answers against the rows as displayed: a row the filter has
    /// hidden is not somewhere the register can land, because it is not there.
    @Test("A filtered-out row is not a place to land")
    func respectsFilter() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.registerFilter = RegisterFilter(statuses: Set(ReconcileState.allCases),
                                                startDate: day(20), endDate: nil)
        #expect(f.model.registerRows.map(\.description) == ["day 20"])
        #expect(f.model.goToDate(day(0)))
        #expect(landedOn(f) == "day 20")
    }

    /// Sorting is display-only, so "the first on or after" is still the earliest
    /// by date even when the rows are shown newest-first.
    @Test("Reversing the sort does not change where a date is")
    func independentOfSort() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.registerSortReversed = true
        #expect(f.model.registerRows.map(\.description) == ["day 20", "day 10", "day 0"])
        #expect(f.model.goToDate(day(5)))
        #expect(landedOn(f) == "day 10")
    }
}
