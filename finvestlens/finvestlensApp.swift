//
//  finvestlensApp.swift
//  finvestlens
//
//  Created by Chris Tham on 12/7/2026.
//
//  This file is part of FinvestLens.
//
//  Copyright (C) 2026 Christine Tham
//
//  FinvestLens is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  FinvestLens is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with FinvestLens.  If not, see <https://www.gnu.org/licenses/>.
//

import SwiftUI
import FinvestLensUI

@main
struct finvestlensApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootHost(model: model)
                .onOpenURL { url in
                    // Opened from Finder / another app via the .finvestlens type.
                    guard url.pathExtension == "finvestlens" else { return }
                    try? model.open(at: url)
                }
                .finvestLensAppearance()
        }
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Save") { try? model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.hasUnsavedChanges)
            }
            CommandMenu("Security") {
                Button(model.requireAuthentication
                       ? "Don’t Require Authentication"
                       : "Require Authentication to Open") {
                    model.requireAuthentication.toggle()
                }
                .disabled(!model.isOpen)
                Button("Lock Now") { model.lockNow() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!model.isOpen || model.isLocked)
            }
        }

        #if os(macOS)
        Settings {
            AppearanceSettingsView()
                .finvestLensAppearance()
        }
        #endif
    }
}
