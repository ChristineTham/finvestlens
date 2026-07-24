//
//  ModelGapTests.swift
//  FinvestLens — Engine
//
//  Coverage for small model members the feature tests never touch: account
//  type classification, account colour and tree edges, lot membership, and
//  identity plumbing on the primitives.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("Account type classification")
struct AccountTypeTests {

    @Test("Asset-like, liability-like and sign conventions for every type")
    func classification() {
        let assetLike: Set<AccountType> = [.asset, .bank, .cash, .stock, .mutualFund, .receivable]
        let liabilityLike: Set<AccountType> = [.liability, .credit, .equity, .income, .payable]
        let debitNormal = assetLike.union([.expense, .trading])
        let securities: Set<AccountType> = [.stock, .mutualFund]

        for type in AccountType.allCases {
            #expect(type.isAssetLike == assetLike.contains(type), "\(type)")
            #expect(type.isLiabilityLike == liabilityLike.contains(type), "\(type)")
            #expect(type.normalBalanceIsDebit == debitNormal.contains(type), "\(type)")
            #expect(type.isSecurityType == securities.contains(type), "\(type)")
        }
        // Root sits outside the asset/liability split entirely.
        #expect(!AccountType.root.isAssetLike && !AccountType.root.isLiabilityLike)
    }
}

@Suite("Account members")
struct AccountMemberTests {

    @Test("Colour honours GnuCash's Not Set sentinel")
    func color() {
        let account = Account(name: "A", type: .bank, commodity: .aud)
        #expect(account.color == nil)
        account.color = " rgb(144,144,238) "
        #expect(account.color == "rgb(144,144,238)")     // trimmed
        #expect(account.kvp["color"] == .string("rgb(144,144,238)"))
        account.kvp["color"] = .string("Not Set")        // GnuCash's sentinel
        #expect(account.color == nil)
        account.color = "#8fbc8f"
        #expect(account.color == "#8fbc8f")
        account.color = ""
        #expect(account.color == nil)
        #expect(account.kvp["color"] == nil)             // cleared, not stored empty
    }

    @Test("Imbalance and Orphan holding accounts are recognised by name")
    func imbalanceOrOrphan() {
        #expect(Account(name: "Imbalance-AUD", type: .bank, commodity: .aud).isImbalanceOrOrphan)
        #expect(Account(name: "Orphan-USD", type: .bank, commodity: .usd).isImbalanceOrOrphan)
        #expect(!Account(name: "Savings", type: .bank, commodity: .aud).isImbalanceOrOrphan)
    }

    @Test("Positional addChild clamps and reparents")
    func addChildAt() {
        let parent = Account(name: "P", type: .asset, commodity: .aud)
        let first = Account(name: "1", type: .bank, commodity: .aud)
        let second = Account(name: "2", type: .bank, commodity: .aud)
        parent.addChild(first)
        parent.addChild(second)

        let inserted = Account(name: "M", type: .bank, commodity: .aud)
        parent.addChild(inserted, at: 1)
        #expect(parent.children.map(\.name) == ["1", "M", "2"])
        #expect(inserted.parent === parent)

        // Out-of-range indexes clamp to the ends.
        let low = Account(name: "L", type: .bank, commodity: .aud)
        parent.addChild(low, at: -5)
        #expect(parent.children.first === low)
        let high = Account(name: "H", type: .bank, commodity: .aud)
        parent.addChild(high, at: 99)
        #expect(parent.children.last === high)

        // Positional insertion reparents from the old parent too.
        let other = Account(name: "O", type: .asset, commodity: .aud)
        other.addChild(inserted, at: 0)
        #expect(inserted.parent === other)
        #expect(!parent.children.contains(where: { $0 === inserted }))
    }

    @Test("removeChild ignores children of other parents")
    func removeChildForeign() {
        let parent = Account(name: "P", type: .asset, commodity: .aud)
        let other = Account(name: "O", type: .asset, commodity: .aud)
        let child = other.addChild(Account(name: "C", type: .bank, commodity: .aud))
        parent.removeChild(child)                    // not ours: no-op
        #expect(child.parent === other)
        #expect(other.children.count == 1)
        other.removeChild(child)
        #expect(child.parent == nil)
        #expect(other.children.isEmpty)
    }

    @Test("Identity semantics and id")
    func identity() {
        let a = Account(name: "A", type: .bank, commodity: .aud)
        let b = Account(name: "A", type: .bank, commodity: .aud)
        #expect(a.id == a.guid)
        #expect(a == a)
        #expect(a != b)
        #expect(Set([a, b, a]).count == 2)
    }
}

@Suite("Lot members")
struct LotMemberTests {

    @Test("Splits enter once, leave cleanly, and net to the balance")
    func membership() {
        let lot = Lot(title: "Invoice #1")
        #expect(lot.isEmpty)
        let posting = Split(value: Decimal(100))
        let payment = Split(value: Decimal(-60))
        lot.add(posting)
        lot.add(posting)                              // idempotent by identity
        lot.add(payment)
        #expect(lot.splits.count == 2)
        #expect(lot.balance == Decimal(40))           // still outstanding
        lot.remove(payment)
        #expect(lot.splits.count == 1)
        #expect(lot.balance == Decimal(100))
        lot.remove(posting)
        #expect(lot.isEmpty)
        #expect(lot.balance == 0)
    }
}

@Suite("Primitive gaps")
struct PrimitiveGapTests {

    @Test("A GUID describes itself as its hex string")
    func guidDescription() {
        let guid = GncGUID.random()
        #expect(guid.description == guid.hexString)
        #expect(guid.id == guid)
        #expect("\(guid)" == guid.hexString)
    }

    @Test("Decoding a malformed GUID throws")
    func guidDecodeFailure() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GncGUID.self, from: Data(#""nothex""#.utf8))
        }
    }

    @Test("A price's id is its guid")
    func priceIdentity() {
        let price = Price(commodity: .usd, currency: .aud,
                          date: Date(timeIntervalSince1970: 0), value: Decimal(string: "1.5")!)
        #expect(price.id == price.guid)
        #expect(price.source == "user:price")
        #expect(price.type == "last")
    }
}
