//
//  DocumentLoaderTests.swift
//  FinvestLens — Persistence
//
//  Pins the off-main-actor load path (Architecture §12.6): a book must be
//  materialised away from the main actor, and the resulting document must be
//  a complete, usable book once it lands.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensPersistence

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

/// Reports the thread the loader's executor actually runs on. Test-only: the
/// production path has no reason to ask.
@DocumentLoader private func loaderRunsOnMainThread() -> Bool { Thread.isMainThread }

@Suite("Document loader")
struct DocumentLoaderTests {

    @Test("The loader's executor is not the main thread")
    @MainActor
    func loaderIsOffTheMainThread() async {
        // If this fails, `load` has been annotated back onto the main actor and
        // opening a large book freezes the window again — the whole point of the
        // global actor.
        #expect(await loaderRunsOnMainThread() == false)
    }

    @Test("A book loaded off the main actor arrives complete")
    @MainActor
    func loadedBookIsComplete() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let created = try FinvestLensDocument.create(at: url)
        let bank = created.book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let salary = created.book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 1_700_000_000),
                              description: "Pay")
        txn.addSplit(account: bank, value: Decimal(string: "100.00")!)
        txn.addSplit(account: salary, value: Decimal(string: "-100.00")!)
        created.book.addTransaction(txn)
        try created.save()
        created.discard()

        // The graph is built on the loader and handed over as a `sending` value.
        let loaded = try await FinvestLensDocument.load(at: url)
        defer { loaded.discard() }
        #expect(loaded.book.transactions.count == 1)
        #expect(loaded.book.rootAccount.descendants.count == 2)
        let bankAccount = try #require(loaded.book.accounts.first { $0.name == "Bank" })
        #expect(loaded.book.balance(of: bankAccount).amount == Decimal(string: "100.00")!)
    }
}
