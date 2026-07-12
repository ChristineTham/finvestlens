//
//  PersistenceTests.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensPersistence

private let day = Date(timeIntervalSince1970: 1_700_000_000)

private func tempURL(_ ext: String = "finvestlens") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(ext)
}

/// Builds a small book: Bank + Salary and one balanced $100 pay transaction.
private func makeBook() -> (Book, GncGUID) {
    let book = Book(baseCurrency: .aud)
    let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
    let income = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
    let txn = Transaction(currency: .aud, datePosted: day, description: "Pay")
    txn.addSplit(account: bank, value: Decimal(string: "100.00")!)
    txn.addSplit(account: income, value: Decimal(string: "-100.00")!)
    book.addTransaction(txn)
    return (book, bank.guid)
}

@Suite("SQLite document store")
struct StoreRoundTripTests {

    @Test("Book survives a write/read round-trip")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let (book, bankGUID) = makeBook()
        let store = try SQLiteDocumentStore(path: url.path)
        try store.write(book)

        let reloaded = try SQLiteDocumentStore(path: url.path).read()
        #expect(reloaded.accounts.count == 2)
        #expect(reloaded.transactions.count == 1)

        let bank = try #require(reloaded.accounts.first { $0.name == "Bank" })
        #expect(bank.guid == bankGUID)                       // GUID preserved
        #expect(bank.fullName == "Bank")
        #expect(reloaded.balance(of: bank).rounded.amount == Decimal(100))

        let aud = try #require(reloaded.commodities.first { $0.mnemonic == "AUD" })
        #expect(aud.namespace == .currency)
    }

    @Test("Change counter increments per write")
    func changeCounter() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (book, _) = makeBook()
        let store = try SQLiteDocumentStore(path: url.path)
        try store.write(book)
        try store.write(book)
        #expect(store.changeCounter == 2)
    }

    @Test("KVP slots persist")
    func kvpPersists() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let book = Book(baseCurrency: .aud)
        let account = Account(name: "Tagged", type: .asset, commodity: .aud)
        account.kvp["note"] = .string("keep me")
        book.addAccount(account)
        try SQLiteDocumentStore(path: url.path).write(book)

        let reloaded = try SQLiteDocumentStore(path: url.path).read()
        let tagged = try #require(reloaded.accounts.first { $0.name == "Tagged" })
        #expect(tagged.kvp["note"] == .string("keep me"))
    }
}

@Suite("File lock")
struct FileLockTests {

    @Test("A second acquirer is refused")
    func mutualExclusion() throws {
        let doc = tempURL()
        let lock1 = FileLock(documentURL: doc)
        let lock2 = FileLock(documentURL: doc)
        defer { lock1.release(); lock2.release() }

        try lock1.acquire()
        #expect(lock1.isHeldByUs)
        #expect(throws: FileLock.LockError.self) { try lock2.acquire() }
    }

    @Test("Releasing lets another acquire")
    func releaseAllowsReacquire() throws {
        let doc = tempURL()
        let lock1 = FileLock(documentURL: doc)
        try lock1.acquire()
        lock1.release()

        let lock2 = FileLock(documentURL: doc)
        defer { lock2.release() }
        try lock2.acquire()
        #expect(lock2.isHeldByUs)
    }

    @Test("A stale lock is detected and can be broken")
    func staleBreaking() throws {
        let doc = tempURL()
        let stale = FileLock(documentURL: doc, staleAfter: 60)
        try stale.acquire(now: Date(timeIntervalSinceNow: -1000)) // long-dead heartbeat

        let fresh = FileLock(documentURL: doc, staleAfter: 60)
        defer { fresh.release() }
        #expect(fresh.isStale())
        try fresh.breakStaleLockAndAcquire()
        #expect(fresh.isHeldByUs)
    }

    @Test("Heartbeat advances the timestamp")
    func heartbeat() throws {
        let doc = tempURL()
        let lock = FileLock(documentURL: doc)
        defer { lock.release() }
        try lock.acquire(now: Date(timeIntervalSinceNow: -100))
        let before = try #require(lock.currentHolder()).heartbeatAt
        try lock.refreshHeartbeat()
        let after = try #require(lock.currentHolder()).heartbeatAt
        #expect(after > before)
    }
}

@Suite("Document lifecycle")
struct DocumentLifecycleTests {

    @Test("Create, save, reopen sees the changes")
    func saveAndReopen() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try FinvestLensDocument.create(at: url)
        let bank = doc.book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let income = doc.book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day, description: "Pay")
        txn.addSplit(account: bank, value: Decimal(string: "100.00")!)
        txn.addSplit(account: income, value: Decimal(string: "-100.00")!)
        doc.book.addTransaction(txn)
        doc.markDirty()
        try doc.save()
        doc.discard()

        let reopened = try FinvestLensDocument.open(at: url)
        defer { reopened.discard() }
        #expect(reopened.book.transactions.count == 1)
        let reBank = try #require(reopened.book.accounts.first { $0.name == "Bank" })
        #expect(reopened.book.balance(of: reBank).rounded.amount == Decimal(100))
    }

    @Test("Discarding a session leaves the shared file unchanged")
    func discardKeepsFileIntact() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try FinvestLensDocument.create(at: url)
        doc.discard()

        let reopen = try FinvestLensDocument.open(at: url)
        let before = try Data(contentsOf: url)
        reopen.book.addAccount(Account(name: "Ghost", type: .asset, commodity: .aud))
        reopen.markDirty()
        reopen.discard()               // close WITHOUT saving

        let after = try Data(contentsOf: url)
        #expect(before == after)       // shared file byte-identical

        let verify = try FinvestLensDocument.open(at: url)
        defer { verify.discard() }
        #expect(verify.book.accounts.first { $0.name == "Ghost" } == nil)
    }

    @Test("Save refuses when the shared file changed underneath")
    func conflictDetection() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try FinvestLensDocument.create(at: url)
        defer { doc.discard() }

        // Simulate an out-of-band writer (bypassed lock).
        try Data("tampered".utf8).write(to: url)

        doc.book.addAccount(Account(name: "X", type: .asset, commodity: .aud))
        doc.markDirty()
        #expect(throws: FinvestLensDocument.DocumentError.conflict) { try doc.save() }
    }

    @Test("Revert restores the last-saved state")
    func revert() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try FinvestLensDocument.create(at: url)
        defer { doc.discard() }
        doc.book.addAccount(Account(name: "Keep", type: .asset, commodity: .aud))
        doc.markDirty()
        try doc.save()

        doc.book.addAccount(Account(name: "Temp", type: .asset, commodity: .aud))
        doc.markDirty()
        try doc.revert()

        #expect(doc.book.accounts.first { $0.name == "Keep" } != nil)
        #expect(doc.book.accounts.first { $0.name == "Temp" } == nil)
        #expect(!doc.hasUnsavedChanges)
    }
}
