import AppKit
import SwiftUI

@main
struct HermesStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioDelegate.self) var delegate
    @StateObject private var studio = StudioModel()

    var body: some Scene {
        Window(StudioBrand.name, id: "studio") {
            StudioWindow(studio: studio)
                .preferredColorScheme(.dark)
                .frame(minWidth: 760, minHeight: 570)
                .task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1800)) } catch { return }
                        studio.refreshArchive()
                    }
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新对话", action: studio.newConversation)
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(studio.showManagement)
                Button("返回工作台", action: studio.goHome)
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(studio.showManagement)
            }
        }
    }
}

final class StudioDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
