import AppKit
import StudioCore
import SwiftUI

@main
struct HermesStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioDelegate.self) var delegate
    @StateObject private var studio = StudioModel()

    var body: some Scene {
        Window(StudioBrand.name, id: "studio") {
            StudioWindow(studio: studio)
                .onAppear {
                    delegate.prepareForTermination = { studio.prepareForTermination() }
                    delegate.releaseIdleProcesses = {
                        if let runtime = studio.groupRuntime { await runtime.releaseIdleWorkers() }
                    }
                }
                .preferredColorScheme(.dark)
                .frame(minWidth: 760, minHeight: 570)
                .task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                        if NSApplication.shared.isActive, let runtime = studio.groupRuntime {
                            studio.groupWorkspace.startIdleChats(runtime: runtime)
                        }
                    }
                }
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
    var prepareForTermination: (() -> Void)?
    var releaseIdleProcesses: (@MainActor () async -> Void)?
    private var terminating = false
    private var memoryPressure: DispatchSourceMemoryPressure?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        prepareForTermination?()
        Task { @MainActor in
            await HermesRuntime.shutdownApplicationProcesses()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, !self.terminating else { return }
                await self.releaseIdleProcesses?()
            }
        }
        memoryPressure = source
        source.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
