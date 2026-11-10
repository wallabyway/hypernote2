import AppKit
import SwiftUI

/// Adds "Launch at Login" to the Dock icon's right-click menu (visible while the window is open).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.target = self
        item.state = AppModel.shared.launchAtLogin ? .on : .off
        menu.addItem(item)
        return menu
    }

    @MainActor @objc private func toggleLaunchAtLogin() {
        AppModel.shared.setLaunchAtLogin(!AppModel.shared.launchAtLogin)
    }
}

@main
struct Hypernote2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("Hypernote2", id: "main") {
            WebHostView(webView: model.webView)
                .frame(minWidth: 880, minHeight: 580)
                .onAppear {
                    // Show a Dock icon + menu bar (needed for ⌘C/⌘V) only while the window is open.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 740)

        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.isRecording ? (model.isPaused ? "pause.circle.fill" : "record.circle.fill") : "waveform")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Hypernote2") { show() }
        Button(model.isRecording ? "Stop Recording" : "Start Recording") {
            Task {
                let wasRecording = model.isRecording
                await model.controller.toggleRecordingFromMenu()
                if !wasRecording { show() }
            }
        }
        if model.isRecording {
            Button(model.isPaused ? "Resume Recording" : "Pause Recording") {
                model.controller.togglePause()
            }
        }
        Divider()
        if let update = model.availableUpdate {
            Button("Install Update \(update)…") { Task { await model.controller.checkForUpdatesInteractively() } }
        } else {
            Button("Check for Updates…") { Task { await model.controller.checkForUpdatesInteractively() } }
        }
        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }))
        Divider()
        Button("Quit Hypernote2") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
