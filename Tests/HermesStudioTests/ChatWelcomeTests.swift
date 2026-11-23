import AppKit
import StudioCore
import SwiftUI
import XCTest
@testable import HermesStudio

final class ChatWelcomeTests: XCTestCase {
    @MainActor
    func testDefaultRecommendationsFillDraftInTheChatPane() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "研发搭档", summary: "适合一起讨论代码、架构与技术决策。", template: .engineering)
        try store.create(role, instructions: "")
        let studio = StudioModel(dataStore: store, runtime: HermesRuntime(executable: URL(fileURLWithPath: "/usr/bin/false")),
            runPreferences: .init())
        studio.select(role)

        let pane = ChatPane(studio: studio).background(StudioPalette.background)
        try await render(pane, width: 900, height: 620, snapshot: "推荐开场-宽窗口.png") { window in
            try click(at: CGPoint(x: 450, y: 210), in: window)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(studio.draft, "帮我分析这个故障，列出优先排查的证据：")
        XCTAssertNil(studio.conversationID)

        if snapshotDirectory != nil {
            studio.draft = ""
            try await render(pane, width: 570, height: 560, snapshot: "推荐开场-常规窗口.png") { _ in }
        }
    }

    @MainActor
    func testLongPersonalizedRecommendationRemainsAnActionInACompactPane() async throws {
        let question = "能不能根据上次的发布检查清单，先梳理登录、搜索和消息推送各自的验证项，再按上线前必须完成和上线后可以补做的顺序排一下？"
        var selected: String?
        let view = ChatWelcomeRecommendations(template: .engineering,
            personalized: [question, "能帮我把这周的回归项整理成检查清单吗？"], loading: false, compact: true) {
                selected = $0
            }
            .padding(18)
            .frame(maxHeight: .infinity, alignment: .center)
            .background(StudioPalette.background)
        try await render(view, width: 350, height: 420, snapshot: "记忆推荐-窄窗口.png") { window in
            try click(at: CGPoint(x: 175, y: 225), in: window)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(selected, question)
    }

    private var snapshotDirectory: URL? {
        ProcessInfo.processInfo.environment["HERMES_STUDIO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    private func render(_ view: some View, width: CGFloat, height: CGFloat, snapshot: String,
        check: (NSWindow) throws -> Void) async throws {
        _ = NSApplication.shared
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height).preferredColorScheme(.dark))
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        if let snapshotDirectory {
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: snapshotDirectory.appendingPathComponent(snapshot), options: .atomic)
        }
        try check(window)
    }

    @MainActor
    private func click(at point: CGPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
}
