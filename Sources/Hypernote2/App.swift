import AppKit
import SwiftUI

@main
struct Hypernote2App: App {
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
            Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
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
        Divider()
        Button("Quit Hypernote2") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
