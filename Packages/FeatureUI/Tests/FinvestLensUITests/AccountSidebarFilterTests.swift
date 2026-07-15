//
//  AccountSidebarFilterTests.swift
//  FinvestLens — FeatureUI
//
//  Filtering and hiding in the account tree.
//
//  `isHidden` was settable, stored and round-tripped from the start, and the
//  sidebar showed every account regardless — marking one hidden greyed its name
//  and did nothing else. And the tree had no filter, though the same filter had
//  already been written and tested one file over for Find's account picker.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Account sidebar filter")
struct AccountSidebarFilterTests {

    /// Mirrors the shape of the reference book: a placeholder parent with real
    /// accounts under it, and a hidden account with a visible child.
    private func tree() -> [AccountNode] {
        func node(_ name: String, _ full: String, hidden: Bool = false,
                  placeholder: Bool = false, children: [AccountNode]? = nil) -> AccountNode {
            AccountNode(id: .random(), name: name, fullName: full, typeName: "Bank",
                        balance: 0, currencyCode: "AUD", isPlaceholder: placeholder,
                        isHidden: hidden, color: nil, children: children)
        }
        return [
            node("Assets", "Assets", placeholder: true, children: [
                node("Joint", "Assets:Joint", placeholder: true, children: [
                    node("CDIA", "Assets:Joint:CDIA"),
                    node("ANZ Access", "Assets:Joint:ANZ Access"),
                ]),
                node("Closed", "Assets:Closed", hidden: true, children: [
                    node("Old Saver", "Assets:Closed:Old Saver"),
                ]),
            ]),
            node("Income", "Income", placeholder: true, children: [
                node("Salary", "Income:Salary"),
            ]),
        ]
    }

    private func names(_ nodes: [AccountNode]) -> [String] {
        nodes.flatMap { [$0.fullName] + names($0.children ?? []) }
    }

    @Test("Hiding a parent hides everything under it")
    func pruningHidden() {
        let pruned = AccountsSidebar.pruningHidden(tree())
        let all = names(pruned)
        #expect(!all.contains("Assets:Closed"))
        // The child is not itself hidden, but a visible child of a hidden
        // parent would have nowhere to hang.
        #expect(!all.contains("Assets:Closed:Old Saver"))
        #expect(all.contains("Assets:Joint:CDIA"))
    }

    @Test("Showing hidden accounts leaves the tree whole")
    func unpruned() {
        #expect(names(tree()).contains("Assets:Closed:Old Saver"))
    }

    /// The point of the filter: four keystrokes instead of three disclosure
    /// triangles.
    @Test("Filtering flattens to matches on the full name")
    func filtering() {
        let matches = AccountMatchPicker.matching(tree(), filter: "cdia",
                                                  includingPlaceholders: true)
        #expect(matches.map(\.fullName) == ["Assets:Joint:CDIA"])
    }

    /// A parent's name finds its children, which is what makes the full name the
    /// thing to match on.
    @Test("A parent's name finds everything under it")
    func parentNameMatchesChildren() {
        let matches = AccountMatchPicker.matching(tree(), filter: "joint",
                                                  includingPlaceholders: true)
        #expect(matches.map(\.fullName).sorted()
                == ["Assets:Joint", "Assets:Joint:ANZ Access", "Assets:Joint:CDIA"])
    }

    /// The sidebar shows placeholders — selecting one opens its register — while
    /// Find's picker must not, since a placeholder holds no splits to match.
    @Test("Placeholders appear in the sidebar filter but not in Find's")
    func placeholderPolicyDiffers() {
        let sidebar = AccountMatchPicker.matching(tree(), filter: "assets",
                                                  includingPlaceholders: true)
        let find = AccountMatchPicker.matching(tree(), filter: "assets")
        #expect(sidebar.map(\.fullName).contains("Assets"))
        #expect(!find.map(\.fullName).contains("Assets"))
        #expect(find.map(\.fullName).contains("Assets:Joint:CDIA"))
    }

    /// Filter and hide compose: a hidden account must not come back just because
    /// you typed its name.
    @Test("Filtering does not resurrect a hidden account")
    func filterRespectsHidden() {
        let visible = AccountsSidebar.pruningHidden(tree())
        let matches = AccountMatchPicker.matching(visible, filter: "old saver",
                                                  includingPlaceholders: true)
        #expect(matches.isEmpty)
        // …but it is findable once hidden accounts are shown.
        let shown = AccountMatchPicker.matching(tree(), filter: "old saver",
                                                includingPlaceholders: true)
        #expect(shown.map(\.fullName) == ["Assets:Closed:Old Saver"])
    }

    @Test("An empty filter matches everything, not nothing")
    func emptyFilter() {
        let matches = AccountMatchPicker.matching(tree(), filter: "",
                                                  includingPlaceholders: true)
        #expect(matches.count == names(tree()).count)
    }
}
