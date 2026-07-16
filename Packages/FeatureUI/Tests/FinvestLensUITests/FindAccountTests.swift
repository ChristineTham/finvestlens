//
//  FindAccountTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's Find Account (⌘I). The matching itself is Find's picker's
//  `matching`, already pinned in AccountSidebarFilterTests — what is new here is
//  the Return rule: act on the chosen row, or on the only match, and never on a
//  guess between several.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Find account")
struct FindAccountTests {

    private func node(_ name: String) -> AccountNode {
        AccountNode(id: .random(), name: name, fullName: name, typeName: "Bank",
                    balance: 0, currencyCode: "AUD", isPlaceholder: false,
                    isHidden: false, color: nil, children: nil)
    }

    @Test("A chosen row wins whatever else matches")
    func selectionWins() {
        let a = node("CDIA"), b = node("CBA")
        #expect(FindAccountSheet.target(selection: b.id, matches: [a, b]) == b.id)
    }

    /// "cdia" narrowing to one account should not also demand an arrow key.
    @Test("The only match is the target without being selected")
    func singleMatchIsEnough() {
        let a = node("CDIA")
        #expect(FindAccountSheet.target(selection: nil, matches: [a]) == a.id)
    }

    /// Several matches and no choice is a question, not an answer — Return must
    /// not jump to whichever happens to be first.
    @Test("Several matches with no choice go nowhere")
    func ambiguityGoesNowhere() {
        #expect(FindAccountSheet.target(selection: nil,
                                        matches: [node("CBA"), node("CDIA")]) == nil)
    }

    @Test("No matches go nowhere")
    func nothingGoesNowhere() {
        #expect(FindAccountSheet.target(selection: nil, matches: []) == nil)
    }
}
