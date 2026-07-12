//
//  Account.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A node in the chart of accounts.
///
/// Accounts form a tree rooted at ``Book/rootAccount``. Each account is
/// denominated in a ``Commodity`` and carries a stable ``GncGUID``. Accounts do
/// not hold their splits directly; balances are computed by the ``Book`` that
/// owns the transactions (see `Book.balance(of:)`). This keeps ownership acyclic
/// (`Book → Transaction → Split → Account`).
public final class Account {

    /// Stable identity, preserved across GnuCash round-trips.
    public let guid: GncGUID
    public var name: String
    public var type: AccountType
    public var code: String
    public var accountDescription: String
    public var notes: String
    public var commodity: Commodity

    /// A placeholder account holds no postings directly (a grouping node).
    public var isPlaceholder: Bool
    /// Hidden accounts are excluded from most default views.
    public var isHidden: Bool

    /// Preserved key-value slots (including keys not modelled natively).
    public var kvp: KvpFrame

    /// The parent account, or `nil` for the root. Weak to avoid a retain cycle.
    public private(set) weak var parent: Account?
    /// Child accounts, owned strongly by this account.
    public private(set) var children: [Account]

    public init(
        guid: GncGUID = .random(),
        name: String,
        type: AccountType,
        commodity: Commodity,
        code: String = "",
        description: String = "",
        notes: String = "",
        isPlaceholder: Bool = false,
        isHidden: Bool = false,
        kvp: KvpFrame = KvpFrame()
    ) {
        self.guid = guid
        self.name = name
        self.type = type
        self.commodity = commodity
        self.code = code
        self.accountDescription = description
        self.notes = notes
        self.isPlaceholder = isPlaceholder
        self.isHidden = isHidden
        self.kvp = kvp
        self.children = []
    }

    // MARK: Tree structure

    /// `true` if this is a root account (no parent, `.root` type).
    public var isRoot: Bool { parent == nil && type == .root }

    /// Adds `child` under this account, reparenting it if necessary.
    @discardableResult
    public func addChild(_ child: Account) -> Account {
        child.parent?.removeChild(child)
        child.parent = self
        children.append(child)
        return child
    }

    /// Removes `child` if it is a direct child of this account.
    public func removeChild(_ child: Account) {
        guard child.parent === self else { return }
        children.removeAll { $0 === child }
        child.parent = nil
    }

    /// All descendant accounts (depth-first, excluding `self`).
    public var descendants: [Account] {
        children.flatMap { [$0] + $0.descendants }
    }

    /// Fully-qualified name, colon-delimited from the top-most non-root ancestor.
    public var fullName: String {
        guard let parent, !parent.isRoot else { return name }
        return parent.fullName + ":" + name
    }
}

extension Account: Identifiable {
    public var id: GncGUID { guid }
}

extension Account: Equatable, Hashable {
    public static func == (lhs: Account, rhs: Account) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
