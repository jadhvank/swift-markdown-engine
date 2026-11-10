//
//  RelativeLinkClickRoutingTests.swift
//  MarkdownEngineTests
//
//  With `LinkStyle.promotesSchemelessTargetsToHTTPS` off, a click on a schemeless target must reach the
//  embedder through `onLinkClick` and be reported as handled — never handed to the system opener, which
//  would send the browser after a host named after the first path segment. The styler tests only cover the
//  attribute; this covers the click, inside a list nested past the old fixed depth of three so the
//  instance-level `maximumNestingLevel` and the link routing are exercised together.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct RelativeLinkClickRoutingTests {

    private static let storage = """
    Intro

    - one
      - two
        - three
          - four
            - five [report.pdf](Attachments/report.pdf) and [회의록.pdf](Attachments/회의록.pdf) and [Docs](https://example.com/a)

    """

    /// Let every `DispatchQueue.main.async` enqueued during the click run.
    private func drainMainQueue() async {
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func makeEditor(onLinkClick: @escaping (String) -> Void) -> (NativeTextViewCoordinator, NativeTextView) {
        // `textViewDidChangeSelection` reads `NSApp.currentEvent`; the shared application must exist.
        _ = NSApplication.shared

        var configuration = MarkdownEditorConfiguration.default
        configuration.link.promotesSchemelessTargetsToHTTPS = false
        configuration.lists.maximumNestingLevel = .max

        var published = Self.storage
        let binding = Binding<String>(get: { published }, set: { published = $0 })
        let coordinator = NativeTextViewCoordinator(
            text: binding, fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: onLinkClick, onInlineSelectionChange: nil
        )
        coordinator.configuration = configuration
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        textView.configuration = configuration
        textView.delegate = coordinator
        coordinator.textView = textView
        // Caret on the first line, so the link line is inactive and carries `.link`.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.rebuildTextStorageAndStyle(textView, from: Self.storage)
        return (coordinator, textView)
    }

    /// The character index of the middle of `needle`'s first occurrence — clear of the link's edit zone,
    /// which turns a click on the first or last visible character into caret placement.
    private func middleIndex(of needle: String, in textView: NSTextView) -> Int {
        let range = (textView.string as NSString).range(of: needle)
        #expect(range.location != NSNotFound)
        return range.location + range.length / 2
    }

    @Test("a relative target in a deeply nested list routes to onLinkClick and is handled")
    func relativeTargetRoutesToEmbedder() async {
        var received: [String] = []
        let (coordinator, textView) = makeEditor { received.append($0) }
        let index = middleIndex(of: "report.pdf", in: textView)

        let link = textView.textStorage?.attribute(.link, at: index, effectiveRange: nil)
        let url = link as? URL
        #expect(url?.scheme == nil)
        #expect(url?.relativeString == "Attachments/report.pdf")

        let handled = coordinator.textView(textView, clickedOnLink: link as Any, at: index)
        await drainMainQueue()

        #expect(handled)
        #expect(received == ["Attachments/report.pdf"])
        #expect(textView.linkClickDidNavigate)
    }

    /// `URL(string:)` percent-encodes non-ASCII, so the embedder receives the encoded form and must decode
    /// before resolving it against its own directory.
    @Test("a non-ASCII relative target reaches the embedder percent-encoded")
    func nonASCIITargetArrivesPercentEncoded() async {
        var received: [String] = []
        let (coordinator, textView) = makeEditor { received.append($0) }
        let index = middleIndex(of: "회의록.pdf", in: textView)
        let link = textView.textStorage?.attribute(.link, at: index, effectiveRange: nil)

        let handled = coordinator.textView(textView, clickedOnLink: link as Any, at: index)
        await drainMainQueue()

        #expect(handled)
        #expect(received.count == 1)
        #expect(received.first?.removingPercentEncoding == "Attachments/회의록.pdf")
    }

    @Test("a target with a scheme still goes to the system opener, not onLinkClick")
    func schemedTargetDeclinedForSystemOpener() async {
        var received: [String] = []
        let (coordinator, textView) = makeEditor { received.append($0) }
        let index = middleIndex(of: "Docs", in: textView)
        let link = textView.textStorage?.attribute(.link, at: index, effectiveRange: nil)
        #expect((link as? URL)?.absoluteString == "https://example.com/a")

        let handled = coordinator.textView(textView, clickedOnLink: link as Any, at: index)
        await drainMainQueue()

        #expect(!handled)
        #expect(received.isEmpty)
    }
}
