//
//  CallbackRefreshTests.swift
//  MarkdownEngineTests
//
//  An embedder's `onLinkClick` and `onBuildContextMenu` capture its per-render state — for a document that
//  resolves relative links against its own folder, which folder that is. When SwiftUI reuses one editor for
//  another document, the wrapper must hand the coordinator the new closures even if the text is unchanged
//  (two documents with the same body take the update's early return), or a click resolves against the
//  previous document. `onLinkClick` used to be set once in `makeCoordinator`, and `onBuildContextMenu` only
//  after that early return.
//

import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEngine

@MainActor
private final class CallbackRefreshModel: ObservableObject {
    @Published var owner = "A"
    var received: [String] = []
}

private struct CallbackRefreshRoot: View {
    @ObservedObject var model: CallbackRefreshModel
    let configuration: MarkdownEditorConfiguration

    var body: some View {
        let owner = model.owner
        let model = self.model
        NativeTextViewWrapper(
            text: .constant(CallbackRefreshTests.text),
            configuration: configuration,
            fontName: "Helvetica",
            fontSize: 15,
            documentId: "callback-refresh",
            isEditable: true,
            onLinkClick: { model.received.append("\(owner) link \($0)") },
            onBuildContextMenu: { menu, _ in
                model.received.append("\(owner) menu")
                return menu
            }
        )
        .frame(width: 480, height: 320)
    }
}

@MainActor
final class CallbackRefreshTests: XCTestCase {

    nonisolated static let text = "Intro\n\n[report.pdf](Attachments/report.pdf)\n"

    private func spin(_ seconds: TimeInterval = 0.12) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func firstSubview<T: NSView>(of root: NSView, as type: T.Type) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = firstSubview(of: child, as: type) { return match }
        }
        return nil
    }

    func testCallbacksFollowTheLatestRenderWhenTheTextIsUnchanged() throws {
        _ = NSApplication.shared
        var configuration = MarkdownEditorConfiguration.default
        configuration.link.promotesSchemelessTargetsToHTTPS = false
        let model = CallbackRefreshModel()
        let hosting = NSHostingView(rootView: CallbackRefreshRoot(model: model, configuration: configuration))
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 480, height: 320),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        spin()

        let textView = try XCTUnwrap(firstSubview(of: hosting, as: NativeTextView.self))
        let coordinator = try XCTUnwrap(textView.delegate as? NativeTextViewCoordinator)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        // The same editor now belongs to another document whose body happens to be identical.
        model.owner = "B"
        spin()

        let needle = (textView.string as NSString).range(of: "report.pdf")
        let index = needle.location + needle.length / 2
        let link = try XCTUnwrap(textView.textStorage?.attribute(.link, at: index, effectiveRange: nil))
        XCTAssertTrue(coordinator.textView(textView, clickedOnLink: link, at: index))
        spin(0.05)

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        _ = coordinator.textView(textView, menu: NSMenu(), for: event, at: index)

        XCTAssertEqual(model.received, ["B link Attachments/report.pdf", "B menu"])
    }
}
