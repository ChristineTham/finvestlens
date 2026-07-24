//
//  EmergencyRecordsView.swift
//  FinvestLens — FeatureUI
//
//  The Emergency Records Organizer (`FR-PLAN-15`, docs/planning-design.md §8):
//  structured key records that travel with the book. The screen can be gated
//  behind local authentication — a view gate, honestly described: the data's
//  protection at rest is the book file's.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

struct EmergencyRecordsView: View {
    @Bindable var model: AppModel
    @AppStorage("emergencyRecords.requireAuth") private var requireAuth = true
    @State private var unlocked = false
    @State private var authFailed = false
    @State private var editing: EmergencyRecord?
    @State private var creating = false

    var body: some View {
        Group {
            if requireAuth && !unlocked {
                lockedView
            } else {
                recordsList
            }
        }
        .navigationTitle("Emergency Records")
        .task { await unlockIfNeeded() }
    }

    private var lockedView: some View {
        ContentUnavailableView {
            Label("Locked", systemImage: "lock.shield")
        } description: {
            Text(authFailed
                 ? "Authentication didn't succeed."
                 : "Emergency records are shown after you authenticate.")
        } actions: {
            Button("Unlock") { Task { await unlockIfNeeded(force: true) } }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func unlockIfNeeded(force: Bool = false) async {
        guard requireAuth, !unlocked, force || !authFailed else { return }
        let ok = await model.authenticator.authenticate(reason: "view emergency records")
        unlocked = ok
        authFailed = !ok
    }

    private var recordsList: some View {
        recordsContent
            .toolbar {
                ToolbarItem {
                    Button("Add Record", systemImage: "plus") { creating = true }
                        .help("Add an emergency record")
                }
                ToolbarItem {
                    Toggle(isOn: $requireAuth) {
                        Label("Require Authentication", systemImage: "lock.shield")
                    }
                    .help("Ask for Touch ID or your password each time this screen opens")
                }
            }
            .sheet(isPresented: $creating) {
                RecordEditorSheet(model: model, record: nil)
            }
            .sheet(item: $editing) { record in
                RecordEditorSheet(model: model, record: record)
            }
    }

    @ViewBuilder
    private var recordsContent: some View {
        if model.emergencyRecords.isEmpty {
            ContentUnavailableView {
                Label("No records yet", systemImage: "cross.case")
            } description: {
                Text("Keep key details — insurance policies, account numbers, contacts — with the book, for when they're needed in a hurry.")
            } actions: {
                Button("Add Record…") { creating = true }
            }
        } else {
            List {
                ForEach(EmergencyRecord.Kind.allCases) { kind in
                    let records = model.emergencyRecords
                        .filter { $0.kind == kind }
                        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    if !records.isEmpty {
                        Section(kind.title) {
                            ForEach(records) { record in
                                Button {
                                    editing = record
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.title)
                                        if let first = record.fields.first, !first.value.isEmpty {
                                            Text("\(first.label): \(first.value)")
                                                .scaledFont(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The audit-log tail (docs/planning-design.md §9) — the sidecar's newest
/// entries, one line per edit operation.
struct AuditLogSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                let entries = model.auditLogTail()
                if entries.isEmpty {
                    ContentUnavailableView("No audit entries yet", systemImage: "list.bullet.rectangle",
                                           description: Text("Each edit is recorded beside the book in \(model.auditLogURL?.lastPathComponent ?? "the audit log")."))
                } else {
                    List(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        HStack {
                            Text(entry.operation)
                            Spacer()
                            Text(entry.date.replacingOccurrences(of: "T", with: "  ")
                                    .replacingOccurrences(of: "Z", with: ""))
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle("Audit Log")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

private struct RecordEditorSheet: View {
    @Bindable var model: AppModel
    let record: EmergencyRecord?
    @Environment(\.dismiss) private var dismiss

    @State private var kind: EmergencyRecord.Kind = .other
    @State private var title = ""
    @State private var fields: [EmergencyRecord.Field] = []
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    ForEach(EmergencyRecord.Kind.allCases) { Text($0.title).tag($0) }
                }
                TextField("Title", text: $title)

                Section("Details") {
                    ForEach($fields) { $field in
                        HStack {
                            TextField("Label", text: $field.label)
                                .frame(width: 140)
                            TextField("Value", text: $field.value)
                            Button(role: .destructive) {
                                fields.removeAll { $0.id == field.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove detail")
                        }
                    }
                    Button("Add Detail", systemImage: "plus") {
                        fields.append(EmergencyRecord.Field())
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 60)
                }

                if record != nil {
                    Section {
                        Button("Delete Record", role: .destructive) {
                            if let record { model.deleteEmergencyRecord(record.id) }
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(record == nil ? "New Record" : "Edit Record")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private func load() {
        guard let record else { return }
        kind = record.kind
        title = record.title
        fields = record.fields
        notes = record.notes
    }

    private func save() {
        var edited = record ?? EmergencyRecord()
        edited.kind = kind
        edited.title = title.trimmingCharacters(in: .whitespaces)
        edited.fields = fields.filter { !$0.label.isEmpty || !$0.value.isEmpty }
        edited.notes = notes
        model.saveEmergencyRecord(edited)
        dismiss()
    }
}
