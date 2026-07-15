//
//  CascadeAccountTests.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's Cascade Account Properties. `Account.color`, `isPlaceholder` and
//  `isHidden` have always been mutable and `Account.descendants` has always
//  existed; there was no function joining them and no way to ask.
//
//  The rule with a wrong answer is that each property is opt-in and applied on
//  its own: hiding a subtree because someone asked to recolour it would be a
//  surprise, and an expensive one.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Cascade account properties")
struct CascadeAccountTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let parent: GncGUID
        let child: GncGUID
        let grandchild: GncGUID
        let outsider: GncGUID
    }

    /// Three levels, so "the subtree" and "the children" are different answers,
    /// plus an account outside it that must never be touched.
    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let parent = try #require(model.addAccount(name: "Investments", type: .asset))
        let child = try #require(model.addAccount(name: "Broker", type: .asset, parentID: parent))
        let grandchild = try #require(model.addAccount(name: "BHP", type: .asset, parentID: child))
        let outsider = try #require(model.addAccount(name: "Bank", type: .bank))

        let book = try #require(model.book)
        book.account(with: parent)?.color = "rgb(144,144,238)"
        book.account(with: parent)?.isPlaceholder = true
        book.account(with: parent)?.isHidden = true
        return Fixture(model: model, url: url, parent: parent, child: child,
                       grandchild: grandchild, outsider: outsider)
    }

    private func account(_ f: Fixture, _ id: GncGUID) throws -> Account {
        try #require(f.model.book?.account(with: id))
    }

    /// The whole subtree, not just the children: a property that stopped one
    /// level down would leave a state nobody asked for.
    @Test("Colour reaches the grandchild, not just the child")
    func colourCascades() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let changed = f.model.cascadeProperties(from: f.parent, .init(color: true))
        #expect(changed == 2)
        #expect(try account(f, f.child).color == "rgb(144,144,238)")
        #expect(try account(f, f.grandchild).color == "rgb(144,144,238)")
    }

    /// The one that matters: ticking one box must not move the others.
    @Test("Only the ticked properties travel")
    func propertiesAreIndependent() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.cascadeProperties(from: f.parent, .init(color: true))

        let child = try account(f, f.child)
        #expect(child.color == "rgb(144,144,238)")
        // Asked for colour; the parent is also a hidden placeholder, and the
        // child must be neither.
        #expect(!child.isPlaceholder)
        #expect(!child.isHidden)
    }

    @Test("Hidden and placeholder cascade when asked for")
    func flagsCascade() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.cascadeProperties(from: f.parent, .init(isPlaceholder: true, isHidden: true))
        let grandchild = try account(f, f.grandchild)
        #expect(grandchild.isPlaceholder)
        #expect(grandchild.isHidden)
        #expect(grandchild.color == nil)   // not asked for
    }

    /// A cascade copies what the parent *is*, including a flag being off — it is
    /// "make the subtree match", not "turn things on".
    @Test("Cascading an off flag turns the subtree off")
    func cascadingOffIsAChange() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let book = try #require(f.model.book)
        book.account(with: f.child)?.isHidden = true
        book.account(with: f.grandchild)?.isHidden = true
        book.account(with: f.parent)?.isHidden = false

        f.model.cascadeProperties(from: f.parent, .init(isHidden: true))
        #expect(!(try account(f, f.child).isHidden))
        #expect(!(try account(f, f.grandchild).isHidden))
    }

    @Test("Nothing outside the subtree is touched")
    func outsiderUntouched() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.cascadeProperties(from: f.parent, .init(color: true, isPlaceholder: true,
                                                        isHidden: true))
        let outsider = try account(f, f.outsider)
        #expect(outsider.color == nil)
        #expect(!outsider.isPlaceholder)
        #expect(!outsider.isHidden)
    }

    @Test("The account itself is unchanged — it is the source")
    func sourceUnchanged() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        f.model.cascadeProperties(from: f.parent, .init(color: true, isPlaceholder: true,
                                                        isHidden: true))
        let parent = try account(f, f.parent)
        #expect(parent.color == "rgb(144,144,238)")
        #expect(parent.isPlaceholder)
        #expect(parent.isHidden)
    }

    @Test("Ticking nothing changes nothing")
    func emptyOptions() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(AppModel.CascadeOptions().isEmpty)
        #expect(f.model.cascadeProperties(from: f.parent, .init()) == 0)
        #expect(try account(f, f.child).color == nil)
    }

    @Test("A leaf has nothing to cascade onto")
    func leaf() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        #expect(f.model.descendantCount(of: f.grandchild) == 0)
        #expect(f.model.cascadeProperties(from: f.grandchild, .init(color: true)) == 0)
    }

    @Test("The count offered is the count changed")
    func countMatches() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let offered = f.model.descendantCount(of: f.parent)
        let changed = f.model.cascadeProperties(from: f.parent, .init(color: true))
        #expect(offered == 2)
        #expect(changed == offered)
    }

    /// One Undo, like every other edit.
    @Test("A cascade is undoable")
    func undoable() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let undo = UndoManager()
        f.model.undoManager = undo
        undo.removeAllActions()

        f.model.cascadeProperties(from: f.parent, .init(color: true))
        #expect(try account(f, f.child).color == "rgb(144,144,238)")
        undo.undo()
        #expect(try account(f, f.child).color == nil)
    }
}
