//
//  AccountMatchPickerTests.swift
//  FinvestLens — FeatureUI
//
//  Filtering the account tree in Find's Account criterion.
//
//  GnuCash shows a tree and no filter; on 559 accounts that means opening three
//  disclosure triangles to reach Assets:Joint:CDIA. The filter is the addition,
//  so it is the part worth pinning.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Account match picker")
struct AccountMatchPickerTests {

    /// Assets (placeholder) → Joint (placeholder) → CDIA, ANZ Access;
    /// Income (placeholder) → Salary.
    private func tree() -> [AccountNode] {
        func node(_ name: String, _ full: String, placeholder: Bool = false,
                  children: [AccountNode]? = nil) -> AccountNode {
            AccountNode(id: .random(), name: name, fullName: full, typeName: "Bank",
                        balance: 0, currencyCode: "AUD", isPlaceholder: placeholder,
                        isHidden: false, color: nil, children: children)
        }
        return [
            node("Assets", "Assets", placeholder: true, children: [
                node("Joint", "Assets:Joint", placeholder: true, children: [
                    node("CDIA", "Assets:Joint:CDIA"),
                    node("ANZ Access", "Assets:Joint:ANZ Access"),
                ]),
            ]),
            node("Income", "Income", placeholder: true, children: [
                node("Salary", "Income:Salary"),
            ]),
        ]
    }

    @Test("An empty filter offers every postable account")
    func emptyFilterMatchesPostable() {
        let hits = AccountMatchPicker.matching(tree(), filter: "")
        #expect(hits.map(\.name).sorted() == ["ANZ Access", "CDIA", "Salary"])
    }

    @Test("Filtering finds an account by its own name")
    func filterByName() {
        let hits = AccountMatchPicker.matching(tree(), filter: "cdia")
        #expect(hits.map(\.fullName) == ["Assets:Joint:CDIA"])
    }

    @Test("Filtering is case-insensitive")
    func filterIsCaseInsensitive() {
        #expect(AccountMatchPicker.matching(tree(), filter: "CDIA").count == 1)
        #expect(AccountMatchPicker.matching(tree(), filter: "cDiA").count == 1)
    }

    /// Matching the full name is what lets a parent's name find its children —
    /// the thing a name-only match would lose.
    @Test("A parent's name finds the accounts under it")
    func filterByAncestorName() {
        let hits = AccountMatchPicker.matching(tree(), filter: "joint")
        #expect(hits.map(\.name).sorted() == ["ANZ Access", "CDIA"])
    }

    @Test("A path fragment narrows further")
    func filterByPathFragment() {
        let hits = AccountMatchPicker.matching(tree(), filter: "joint:cd")
        #expect(hits.map(\.fullName) == ["Assets:Joint:CDIA"])
    }

    /// Placeholders hold no splits, so selecting one matches nothing. Offering
    /// them as results would be offering a dead end.
    @Test("Placeholders are never results")
    func placeholdersAreNotResults() {
        #expect(AccountMatchPicker.matching(tree(), filter: "assets").allSatisfy { !$0.isPlaceholder })
        #expect(AccountMatchPicker.matching(tree(), filter: "Income").map(\.name) == ["Salary"])
    }

    @Test("No match is empty, not everything")
    func noMatch() {
        #expect(AccountMatchPicker.matching(tree(), filter: "zzzz").isEmpty)
    }
}
