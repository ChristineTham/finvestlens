//
//  SQLiteDocumentStore.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import FinvestLensEngine

/// The native `.finvestlens` document store — a single SQLite database managed
/// by GRDB (Architecture ADR-2).
///
/// The in-memory ``Book`` is the source of truth; this store snapshots it to
/// SQLite (`write`) and materialises it back (`read`). Snapshot semantics match
/// the document model: load into memory, edit, write back on explicit save.
/// GUIDs and KVP slots are persisted for GnuCash round-trip fidelity.
public final class SQLiteDocumentStore {

    private let dbQueue: DatabaseQueue

    /// The current change counter, bumped on every ``write(_:)``. Used by the
    /// document layer for conflict detection on write-back (`FR-DAT-08`).
    public private(set) var changeCounter: Int64 = 0

    /// Opens (creating if needed) a store at `path` and migrates its schema.
    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
        changeCounter = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'changeCounter'")
                .flatMap { $0 } ?? 0
        }
    }

    // MARK: Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
            try db.create(table: "commodity") { t in
                t.column("namespace", .text).notNull()
                t.column("mnemonic", .text).notNull()
                t.column("fullName", .text).notNull()
                t.column("smallestFraction", .integer).notNull()
                t.column("roundingMode", .text).notNull()
                t.primaryKey(["namespace", "mnemonic"])
            }
            try db.create(table: "account") { t in
                t.primaryKey("guid", .text)
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("code", .text).notNull().defaults(to: "")
                t.column("accountDescription", .text).notNull().defaults(to: "")
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("commodityNamespace", .text).notNull()
                t.column("commodityMnemonic", .text).notNull()
                t.column("placeholder", .boolean).notNull().defaults(to: false)
                t.column("hidden", .boolean).notNull().defaults(to: false)
                t.column("parentGuid", .text)
                t.column("kvp", .text)
            }
            try db.create(table: "txn") { t in
                t.primaryKey("guid", .text)
                t.column("currencyNamespace", .text).notNull()
                t.column("currencyMnemonic", .text).notNull()
                t.column("datePosted", .datetime).notNull()
                t.column("dateEntered", .datetime).notNull()
                t.column("num", .text).notNull().defaults(to: "")
                t.column("transactionDescription", .text).notNull().defaults(to: "")
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("kvp", .text)
            }
            try db.create(table: "split") { t in
                t.primaryKey("guid", .text)
                t.column("txnGuid", .text).notNull()
                    .references("txn", column: "guid", onDelete: .cascade)
                t.column("accountGuid", .text)
                t.column("value", .text).notNull()
                t.column("quantity", .text).notNull()
                t.column("reconcileState", .text).notNull()
                t.column("reconcileDate", .datetime)
                t.column("memo", .text).notNull().defaults(to: "")
                t.column("action", .text).notNull().defaults(to: "")
                t.column("kvp", .text)
            }
            try db.create(index: "split_by_account", on: "split", columns: ["accountGuid"])
            try db.create(index: "split_by_txn", on: "split", columns: ["txnGuid"])
        }
        migrator.registerMigration("v2_prices") { db in
            try db.create(table: "price") { t in
                t.primaryKey("guid", .text)
                t.column("commodityNamespace", .text).notNull()
                t.column("commodityMnemonic", .text).notNull()
                t.column("currencyNamespace", .text).notNull()
                t.column("currencyMnemonic", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("value", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "")
                t.column("type", .text).notNull().defaults(to: "")
            }
        }
        return migrator
    }

    // MARK: Write (snapshot the book)

    /// Replaces the entire database contents with a snapshot of `book` and bumps
    /// the change counter, in a single transaction.
    public func write(_ book: Book) throws {
        try dbQueue.write { db in
            for table in ["split", "txn", "account", "commodity", "price"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }

            for commodity in book.commodities {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO commodity
                    (namespace, mnemonic, fullName, smallestFraction, roundingMode)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [
                        Serialize.namespace(commodity.namespace), commodity.mnemonic,
                        commodity.fullName, commodity.smallestFraction, commodity.roundingMode.rawValue,
                    ])
            }

            for account in [book.rootAccount] + book.rootAccount.descendants {
                try db.execute(sql: """
                    INSERT INTO account
                    (guid, name, type, code, accountDescription, notes,
                     commodityNamespace, commodityMnemonic, placeholder, hidden, parentGuid, kvp)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        account.guid.hexString, account.name, account.type.rawValue,
                        account.code, account.accountDescription, account.notes,
                        Serialize.namespace(account.commodity.namespace), account.commodity.mnemonic,
                        account.isPlaceholder, account.isHidden,
                        account.parent.map { $0.guid.hexString }, Serialize.kvp(account.kvp),
                    ])
            }

            for txn in book.transactions {
                try db.execute(sql: """
                    INSERT INTO txn
                    (guid, currencyNamespace, currencyMnemonic, datePosted, dateEntered,
                     num, transactionDescription, notes, kvp)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        txn.guid.hexString, Serialize.namespace(txn.currency.namespace),
                        txn.currency.mnemonic, txn.datePosted, txn.dateEntered,
                        txn.number, txn.transactionDescription, txn.notes, Serialize.kvp(txn.kvp),
                    ])
                for split in txn.splits {
                    try db.execute(sql: """
                        INSERT INTO split
                        (guid, txnGuid, accountGuid, value, quantity,
                         reconcileState, reconcileDate, memo, action, kvp)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            split.guid.hexString, txn.guid.hexString, split.account?.guid.hexString,
                            Serialize.decimal(split.value), Serialize.decimal(split.quantity),
                            split.reconcileState.rawValue, split.reconcileDate,
                            split.memo, split.action, Serialize.kvp(split.kvp),
                        ])
                }
            }

            for price in book.prices {
                try db.execute(sql: """
                    INSERT INTO price
                    (guid, commodityNamespace, commodityMnemonic, currencyNamespace, currencyMnemonic,
                     date, value, source, type)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        price.guid.hexString,
                        Serialize.namespace(price.commodity.namespace), price.commodity.mnemonic,
                        Serialize.namespace(price.currency.namespace), price.currency.mnemonic,
                        price.date, Serialize.decimal(price.value), price.source, price.type,
                    ])
            }

            changeCounter += 1
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('changeCounter', ?)",
                           arguments: [changeCounter])
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('bookGuid', ?)",
                           arguments: [book.guid.hexString])
            let bookKvp = Serialize.kvp(book.kvp)
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('bookKvp', ?)",
                           arguments: [bookKvp])
        }
    }

    // MARK: Read (materialise the book)

    /// Reconstructs the in-memory ``Book`` from the database.
    public func read() throws -> Book {
        try dbQueue.read { db in
            // Commodities, keyed for lookup.
            var commodityByKey: [String: Commodity] = [:]
            var commodities: [Commodity] = []
            for row in try Row.fetchAll(db, sql: "SELECT * FROM commodity") {
                let commodity = Commodity(
                    namespace: Serialize.parseNamespace(row["namespace"]),
                    mnemonic: row["mnemonic"],
                    fullName: row["fullName"],
                    smallestFraction: row["smallestFraction"],
                    roundingMode: MoneyRoundingMode(rawValue: row["roundingMode"]) ?? .plain
                )
                commodities.append(commodity)
                commodityByKey[Serialize.commodityKey(commodity)] = commodity
            }
            func commodity(_ namespace: String, _ mnemonic: String) -> Commodity {
                commodityByKey["\(namespace)|\(mnemonic)"]
                    ?? Commodity(namespace: Serialize.parseNamespace(namespace),
                                 mnemonic: mnemonic, fullName: mnemonic, smallestFraction: 100)
            }

            // Accounts.
            var accountsByGUID: [GncGUID: Account] = [:]
            var parentByGUID: [GncGUID: GncGUID] = [:]
            var order: [GncGUID] = []
            var root: Account?
            for row in try Row.fetchAll(db, sql: "SELECT * FROM account") {
                guard let guid = GncGUID(hex: row["guid"]) else { continue }
                let account = Account(
                    guid: guid,
                    name: row["name"],
                    type: AccountType(rawValue: row["type"]) ?? .asset,
                    commodity: commodity(row["commodityNamespace"], row["commodityMnemonic"]),
                    code: row["code"],
                    description: row["accountDescription"],
                    notes: row["notes"],
                    isPlaceholder: row["placeholder"],
                    isHidden: row["hidden"],
                    kvp: Serialize.parseKvp(row["kvp"])
                )
                accountsByGUID[guid] = account
                order.append(guid)
                if account.type == .root {
                    root = account
                } else if let parentHex: String = row["parentGuid"], let parent = GncGUID(hex: parentHex) {
                    parentByGUID[guid] = parent
                }
            }

            let rootAccount = root ?? Account(name: "Root Account", type: .root, commodity: .aud)
            let bookGuid = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'bookGuid'")
                .flatMap { $0 }.flatMap { GncGUID(hex: $0) } ?? .random()
            let book = Book(guid: bookGuid, rootAccount: rootAccount)
            for commodity in commodities { book.registerCommodity(commodity) }
            if let bookKvp = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'bookKvp'")
                .flatMap({ $0 }) {
                book.kvp = Serialize.parseKvp(bookKvp)
            }

            for guid in order {
                guard let account = accountsByGUID[guid], account.type != .root else { continue }
                if let parent = parentByGUID[guid], let parentAccount = accountsByGUID[parent] {
                    parentAccount.addChild(account)
                } else {
                    rootAccount.addChild(account)
                }
            }

            // Transactions and their splits.
            var splitsByTxn: [String: [Row]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM split") {
                splitsByTxn[row["txnGuid"], default: []].append(row)
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM txn") {
                guard let guid = GncGUID(hex: row["guid"]) else { continue }
                let txn = Transaction(
                    guid: guid,
                    currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                    datePosted: row["datePosted"],
                    dateEntered: row["dateEntered"],
                    number: row["num"],
                    description: row["transactionDescription"],
                    notes: row["notes"],
                    kvp: Serialize.parseKvp(row["kvp"])
                )
                for splitRow in splitsByTxn[row["guid"]] ?? [] {
                    let split = Split(
                        guid: GncGUID(hex: splitRow["guid"]) ?? .random(),
                        account: (splitRow["accountGuid"] as String?).flatMap { GncGUID(hex: $0) }
                            .flatMap { accountsByGUID[$0] },
                        value: Serialize.parseDecimal(splitRow["value"]),
                        quantity: Serialize.parseDecimal(splitRow["quantity"]),
                        reconcileState: ReconcileState(rawValue: splitRow["reconcileState"]) ?? .notReconciled,
                        reconcileDate: splitRow["reconcileDate"],
                        memo: splitRow["memo"],
                        action: splitRow["action"],
                        kvp: Serialize.parseKvp(splitRow["kvp"])
                    )
                    txn.addSplit(split)
                }
                book.addTransaction(txn)
            }

            // Prices.
            for row in try Row.fetchAll(db, sql: "SELECT * FROM price") {
                guard let guid = GncGUID(hex: row["guid"]) else { continue }
                book.addPrice(Price(
                    guid: guid,
                    commodity: commodity(row["commodityNamespace"], row["commodityMnemonic"]),
                    currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                    date: row["date"],
                    value: Serialize.parseDecimal(row["value"]),
                    source: row["source"],
                    type: row["type"]
                ))
            }

            return book
        }
    }
}
