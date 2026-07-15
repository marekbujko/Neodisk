//
//  NeodiskCommands.swift
//  Neodisk
//
//  The menu bar commands, extracted from NeodiskApp so the scene body
//  stays small.
//

import AppKit
import SwiftUI

struct NeodiskCommands: Commands {
    let model: NeodiskViewModel
    @ObservedObject var updates: UpdateController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            AboutMenuItem()
        }

        CommandGroup(after: .appInfo) {
            Button {
                updates.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!updates.canCheckForUpdates)
        }

        CommandGroup(replacing: .newItem) {
            Button {
                model.chooseFolderAndScan()
            } label: {
                Label("Add Folder…", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("o")

            Button {
                model.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .disabled(!model.coordinator.canRescan || model.coordinator.snapshot == nil)

            Button {
                model.stopScan()
            } label: {
                Label("Stop Scan", systemImage: "stop.circle")
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!model.coordinator.isScanning)
        }

        CommandGroup(after: .textEditing) {
            Button {
                model.search.requestFocus()
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f")
            .disabled(model.coordinator.snapshot == nil)
        }

        CommandGroup(after: .sidebar) {
            Button {
                withAnimation {
                    model.sidebarVisibility =
                        model.sidebarVisibility == .detailOnly ? .all : .detailOnly
                }
            } label: {
                Label(
                    model.sidebarVisibility == .detailOnly
                        ? "Show Locations Sidebar"
                        : "Hide Locations Sidebar",
                    systemImage: "sidebar.left"
                )
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

            Button {
                model.showKindStats.toggle()
            } label: {
                Label(
                    model.showKindStats ? "Hide Statistics" : "Show Statistics",
                    systemImage: "sidebar.right"
                )
            }
            .keyboardShortcut("k", modifiers: [.control, .command])
            .disabled(model.coordinator.snapshot == nil)
        }

        // No help book; the app is meant to be self-explanatory. Help
        // points at the GitHub repo instead.
        CommandGroup(replacing: .help) {
            Button {
                NSWorkspace.shared.open(AppLinks.repository)
            } label: {
                Label("Neodisk on GitHub", systemImage: "link")
            }

            Button {
                NSWorkspace.shared.open(AppLinks.reportIssue)
            } label: {
                Label("Report Issue…", systemImage: "flag")
            }

            Button {
                NSWorkspace.shared.open(AppLinks.sponsor)
            } label: {
                Label("Support Neodisk…", systemImage: "heart")
            }
        }
    }
}

/// The About menu item needs `openWindow`, which is only available through
/// the SwiftUI environment — hence a view instead of an inline Button.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "about")
        } label: {
            Label("About Neodisk", systemImage: "info.circle")
        }
    }
}
