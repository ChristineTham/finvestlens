//
//  AppModel+Audit.swift
//  FinvestLens — FeatureUI
//
//  The audit log (P9, docs/planning-design.md §9): a GnuCash-style append-only
//  sidecar beside the document, one line per edit operation, written on the
//  same code path as undo registration so it can't drift from what actually
//  happened. The log never enters the book file, and rotates at a size cap.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

@MainActor
extension AppModel {

    /// The sidecar's location: `<book>.audit.log` beside the document.
    var auditLogURL: URL? {
        documentURL.map { URL(fileURLWithPath: $0.path + ".audit.log") }
    }

    private static let auditSizeCap = 1 << 20          // rotate past 1 MB…
    private static let auditKeepBytes = 1 << 19        // …keeping the last 512 KB

    /// Appends one operation line: ISO-8601 timestamp, tab, operation name.
    /// Undo/redo replays are labelled as such. Failures are ignored — the log
    /// is an aid, never a reason an edit can't proceed.
    func auditLog(_ operation: String) {
        guard let url = auditLogURL else { return }
        var label = operation
        if undoManager?.isUndoing == true { label = "Undo " + label }
        else if undoManager?.isRedoing == true { label = "Redo " + label }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)\t\(label)\n"

        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? Data(line.utf8).write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))

        if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > Self.auditSizeCap {
            rotateAuditLog(at: url)
        }
    }

    /// Trims the log to its newest tail, cutting at a line boundary.
    private func rotateAuditLog(at url: URL) {
        guard let data = try? Data(contentsOf: url), data.count > Self.auditKeepBytes else { return }
        var tail = data.suffix(Self.auditKeepBytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? tail.write(to: url)
    }

    /// The newest entries, most recent first, for the viewer.
    public func auditLogTail(limit: Int = 500) -> [(date: String, operation: String)] {
        guard let url = auditLogURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).suffix(limit).reversed().map { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            let date = parts.first.map(String.init) ?? ""
            let operation = parts.count > 1 ? String(parts[1]) : ""
            return (date, operation)
        }
    }
}
