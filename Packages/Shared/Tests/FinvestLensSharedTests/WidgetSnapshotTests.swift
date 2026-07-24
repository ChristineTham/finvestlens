//
//  WidgetSnapshotTests.swift
//  FinvestLens — Shared
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import FinvestLensShared

struct WidgetSnapshotTests {

    @Test func roundTripsThroughJSON() throws {
        let snap = WidgetSnapshot(
            bookName: "Ashley Bears",
            netWorth: "$1,234.00",
            upcomingBills: "2 bills due · $50.00",
            alerts: [.init(title: "Bill due", message: "Rent", severity: 2)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded == snap)
    }

    @Test func appGroupIdentifierMatchesEntitlement() {
        #expect(SharedAppGroup.identifier == "group.com.hellotham.finvestlensapp")
    }

    @Test func placeholderIsStable() {
        #expect(WidgetSnapshot.placeholder.bookName == "FinvestLens")
        #expect(WidgetSnapshot.placeholder.alerts.isEmpty)
        #expect(WidgetSnapshot.placeholder.netWorth == "$0.00")
        #expect(WidgetSnapshot.placeholder.upcomingBills == "No upcoming bills")
        #expect(WidgetSnapshot.placeholder.updatedAt == Date(timeIntervalSinceReferenceDate: 0))
    }

    /// The exact JSON the app writes today (default `JSONEncoder`, dates as
    /// seconds since the reference date). The widget extension is a separate
    /// process that may lag an app update, so the wire format must stay
    /// decodable as-is.
    @Test func decodesTheDocumentedWireFormat() throws {
        let json = """
        {"alerts":[{"title":"Bill due","message":"Rent","severity":2}],\
        "upcomingBills":"2 bills due · $50.00","netWorth":"$3,825,458.71",\
        "bookName":"Ashley Bears","updatedAt":806570717.900672}
        """
        let snap = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        #expect(snap.bookName == "Ashley Bears")
        #expect(snap.netWorth == "$3,825,458.71")
        #expect(snap.upcomingBills == "2 bills due · $50.00")
        #expect(snap.alerts == [.init(title: "Bill due", message: "Rent", severity: 2)])
        #expect(snap.updatedAt == Date(timeIntervalSinceReferenceDate: 806570717.900672))
    }

    @Test func truncatedPayloadsFailToDecode() {
        // Every field is required: an extension paired with a newer app that
        // dropped a field would rather fall back to the placeholder than show
        // half a snapshot.
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(#"{"bookName":"X"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(WidgetSnapshot.self, from: Data("not json".utf8))
        }
    }

    @Test func snapshotURLDerivesFromTheContainer() {
        if let container = SharedAppGroup.containerURL {
            let expected = container.appendingPathComponent("widget-snapshot.json", isDirectory: false)
            #expect(SharedAppGroup.snapshotURL == expected)
        } else {
            #expect(SharedAppGroup.snapshotURL == nil)
        }
        #expect(SharedAppGroup.defaults != nil)
    }

    /// Round-trips `write()`/`read()` through the real App Group container when
    /// this process can reach it, restoring whatever was there. In environments
    /// without the container (or without write access) it asserts the no-op
    /// contract instead: `write()` reports `false` and never corrupts the file.
    @Test func writeReadRoundTripThroughAppGroup() throws {
        guard let url = SharedAppGroup.snapshotURL else {
            #expect(WidgetSnapshot.placeholder.write() == false)
            #expect(WidgetSnapshot.read() == nil)
            return
        }
        let original = try? Data(contentsOf: url)
        defer {
            if let original {
                try? original.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let snap = WidgetSnapshot(
            bookName: "Round Trip \(UUID().uuidString.prefix(8))",
            netWorth: "$9.99",
            upcomingBills: "1 bill due · $9.99",
            alerts: [.init(title: "T", message: "M", severity: 0)],
            updatedAt: Date(timeIntervalSinceReferenceDate: 123_456)
        )
        if snap.write() {
            #expect(WidgetSnapshot.read() == snap)
        } else {
            // Write refused (sandboxed test runner): the published snapshot
            // must be untouched.
            #expect((try? Data(contentsOf: url)) == original)
        }
    }
}
