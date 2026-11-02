//
//  FitsContentCaretRevealTests.swift
//  MarkdownEngineTests
//
//  The live hierarchy `HeightBehaviorTests` documents as a coverage gap: a
//  `.fitsContent` editor inside a real SwiftUI `ScrollView`, hosted in a window,
//  with a real run loop. `.fitsContent` growth reaches the outer scroller only
//  after SwiftUI re-queries `sizeThatFits`, so a reveal computed too early is
//  clamped to the old document height and the caret stays below the clip.
//

import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEngine

@MainActor
private final class RevealHarnessModel: ObservableObject {
    @Published var text: String
    init(text: String) { self.text = text }
}

private struct RevealHarnessRoot: View {
    @ObservedObject var model: RevealHarnessModel
    let configuration: MarkdownEditorConfiguration

    var body: some View {
        ScrollView(.vertical) {
            NativeTextViewWrapper(
                text: $model.text,
                configuration: configuration,
                fontName: "Helvetica",
                fontSize: 15,
                documentId: "reveal-harness",
                isEditable: true
            )
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 480, height: 320)
    }
}

@MainActor
private final class RevealHarness {
    let window: NSWindow
    let model: RevealHarnessModel
    let textView: NativeTextView
    let outerScrollView: NSScrollView

    init(text: String, configuration: MarkdownEditorConfiguration? = nil) throws {
        _ = NSApplication.shared
        var config = configuration ?? MarkdownEditorConfiguration.default
        config.heightBehavior = .fitsContent
        config.readingWidth = nil
        config.textInsets = TextInsets(horizontal: 0, vertical: 8)
        let model = RevealHarnessModel(text: text)
        self.model = model
        let hosting = NSHostingView(rootView: RevealHarnessRoot(model: model, configuration: config))
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 480, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window
        Self.spin()

        func firstSubview<T: NSView>(of root: NSView, as type: T.Type) -> T? {
            if let match = root as? T { return match }
            for child in root.subviews {
                if let match = firstSubview(of: child, as: type) { return match }
            }
            return nil
        }
        self.textView = try XCTUnwrap(firstSubview(of: hosting, as: NativeTextView.self))
        let inner = try XCTUnwrap(textView.enclosingScrollView)
        var ancestor = inner.superview
        var outer: NSScrollView?
        while let view = ancestor {
            if let candidate = view as? NSScrollView { outer = candidate; break }
            ancestor = view.superview
        }
        self.outerScrollView = try XCTUnwrap(outer)
        window.makeFirstResponder(textView)
        Self.spin()
    }

    deinit {
        let window = self.window
        MainActor.assumeIsolated { window.close() }
    }

    static func spin(_ seconds: TimeInterval = 0.12) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// The caret's line, in the outer scroller's clip coordinates. Not `firstRect(forCharacterRange:)`: it answers
    /// a zero rect on the empty last line, which reads as "plenty of room" exactly where this feature matters.
    var caretRectInClip: NSRect {
        get throws {
            let rect = try XCTUnwrap(textView.caretLineRect(forOffset: textView.selectedRange().location))
            return outerScrollView.contentView.convert(rect, from: textView)
        }
    }

    /// The room left under the caret's line inside the visible clip; negative when the line is cut off.
    var roomBelowCaret: CGFloat {
        get throws { try outerScrollView.contentView.bounds.maxY - caretRectInClip.maxY }
    }

    var clipY: CGFloat { outerScrollView.contentView.bounds.origin.y }

    func pressReturn() { textView.insertNewline(nil) }

    func type(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    /// One Korean syllable the way the input method delivers it: composed as marked text, then committed.
    func typeComposed(_ syllable: String) {
        textView.setMarkedText(
            syllable, selectedRange: NSRange(location: (syllable as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        Self.spin(0.01)
        textView.insertText(syllable, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func moveCaret(toLine line: Int) {
        let ns = textView.string as NSString
        var location = 0
        for _ in 0..<line {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
        }
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    func scrollOuter(toY y: CGFloat) {
        let clip = outerScrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        outerScrollView.reflectScrolledClipView(clip)
        Self.spin(0.05)
    }
}

@MainActor
final class FitsContentCaretRevealTests: XCTestCase {

    private func lines(_ count: Int) -> String {
        (0..<count).map { "line \($0)" }.joined(separator: "\n")
    }

    /// Return at the document end, over and over: every new line must end up on screen by itself.
    func testReturnAtDocumentEndKeepsCaretVisible() throws {
        let harness = try RevealHarness(text: "")
        for index in 0..<30 {
            harness.type("line \(index)")
            harness.pressReturn()
            RevealHarness.spin()
            XCTAssertGreaterThanOrEqual(try harness.roomBelowCaret, 0, "line cut off after Return #\(index)")
        }
        XCTAssertGreaterThan(harness.clipY, 0, "the page never scrolled")
    }

    /// The same at typing speed: the next key arrives before SwiftUI has finished growing the page.
    func testBurstOfReturnsSettlesWithCaretVisible() throws {
        let harness = try RevealHarness(text: "")
        for index in 0..<40 {
            harness.type("line \(index)")
            harness.pressReturn()
            RevealHarness.spin(0.005)
        }
        RevealHarness.spin()
        XCTAssertGreaterThanOrEqual(try harness.roomBelowCaret, 0)
    }

    /// A long line that soft-wraps at the document end grows the document with no Return at all.
    func testSoftWrapAtDocumentEndKeepsCaretVisible() throws {
        let harness = try RevealHarness(text: lines(14) + "\n")
        for index in 0..<160 {
            harness.type("word ")
            RevealHarness.spin(0.03)
            if index % 20 == 0 {
                XCTAssertGreaterThanOrEqual(try harness.roomBelowCaret, 0, "line cut off at word \(index)")
            }
        }
        RevealHarness.spin()
        XCTAssertGreaterThanOrEqual(try harness.roomBelowCaret, 0)
        XCTAssertGreaterThan(harness.clipY, 0, "the page never scrolled")
    }

    /// Korean arrives as marked text and then a commit; a wrap during that dance must reveal too.
    func testComposedKoreanSoftWrapKeepsCaretVisible() throws {
        let harness = try RevealHarness(text: lines(14) + "\n")
        for index in 0..<220 {
            harness.typeComposed("가")
            RevealHarness.spin(0.02)
            if index % 40 == 0 {
                XCTAssertGreaterThanOrEqual(try harness.roomBelowCaret, 0, "line cut off at syllable \(index)")
            }
        }
        RevealHarness.spin()
        XCTAssertGreaterThanOrEqual(try harness.roomBelowCaret, 0)
        XCTAssertGreaterThan(harness.clipY, 0, "the page never scrolled")
    }

    /// Mid-composition, before any commit: the new wrapped line already has to be on screen.
    func testMarkedTextThatWrapsIsRevealedBeforeItCommits() throws {
        let harness = try RevealHarness(text: lines(16) + "\n" + String(repeating: "word ", count: 18))
        RevealHarness.spin()
        for _ in 0..<40 {
            let before = harness.textView.frame.height
            harness.textView.setMarkedText(
                "가", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            RevealHarness.spin(0.05)
            if harness.textView.frame.height > before {
                XCTAssertGreaterThanOrEqual(try harness.roomBelowCaret, 0)
                return
            }
            harness.textView.insertText("가", replacementRange: NSRange(location: NSNotFound, length: 0))
            RevealHarness.spin(0.02)
        }
        XCTFail("the composing text never wrapped")
    }

    /// Return in the middle of a long note with the caret on the viewport's last visible line.
    func testReturnMidDocumentAtViewportBottomKeepsCaretVisible() throws {
        let harness = try RevealHarness(text: lines(60))
        harness.moveCaret(toLine: 12)
        RevealHarness.spin()
        for index in 0..<16 {
            harness.pressReturn()
            RevealHarness.spin()
            XCTAssertGreaterThanOrEqual(try harness.roomBelowCaret, 0, "line cut off after Return #\(index)")
        }
    }

    /// A multi-line paste at the end lands the caret several lines past the old document end.
    func testMultiLineInsertAtDocumentEndKeepsCaretVisible() throws {
        let harness = try RevealHarness(text: lines(10) + "\n")
        harness.type(lines(40))
        RevealHarness.spin()
        XCTAssertGreaterThanOrEqual(try harness.roomBelowCaret, 0)
    }

    /// The embedder's margin is kept under the caret, given a page with the room to honor it.
    func testBottomMarginIsKeptUnderTheCaret() throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.caretRevealBottomMargin = 64
        let harness = try RevealHarness(text: lines(60), configuration: configuration)
        harness.moveCaret(toLine: 12)
        RevealHarness.spin()
        for _ in 0..<8 {
            harness.pressReturn()
            RevealHarness.spin()
            XCTAssertGreaterThanOrEqual(try harness.roomBelowCaret, 64 - 0.5)
        }
    }

    /// Typing where the caret already has room must not move the page.
    func testTypingWithRoomToSpareDoesNotScroll() throws {
        let harness = try RevealHarness(text: lines(60))
        harness.moveCaret(toLine: 3)
        harness.type("x")
        RevealHarness.spin()
        XCTAssertEqual(harness.clipY, 0)
        for _ in 0..<10 {
            harness.type("y")
            RevealHarness.spin(0.02)
        }
        XCTAssertEqual(harness.clipY, 0)
    }

    /// A document replaced from outside, with the editor unfocused, must not scroll the page.
    func testUnfocusedEditorIgnoresProgrammaticGrowth() throws {
        let harness = try RevealHarness(text: "short")
        harness.window.makeFirstResponder(nil)
        harness.model.text = lines(80)
        RevealHarness.spin()
        XCTAssertEqual(harness.clipY, 0)
    }
}

final class BulletMarkerShapeTests: XCTestCase {

    func testShapesRepeatInOrderPastTheLastOne() {
        let cycle = BulletMarkerShape.allCases
        XCTAssertEqual(cycle.count, 4)
        for level in 0..<40 {
            XCTAssertEqual(BulletMarkerShape.forLevel(level), cycle[level % cycle.count])
        }
        XCTAssertEqual(BulletMarkerShape.forLevel(4), .disc)
        XCTAssertEqual(BulletMarkerShape.forLevel(5), .circle)
    }

    func testOutOfRangeLevelStillHasAMarker() {
        XCTAssertEqual(BulletMarkerShape.forLevel(-1), .disc)
        XCTAssertEqual(BulletMarkerShape.forLevel(1_000), BulletMarkerShape.forLevel(1_000 % 4))
    }
}

@MainActor
final class ListNestingLimitTests: XCTestCase {

    private func textView(text: String, maximumNestingLevel: Int?) -> NativeTextView {
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        var configuration = MarkdownEditorConfiguration.default
        if let maximumNestingLevel { configuration.lists.maximumNestingLevel = maximumNestingLevel }
        view.configuration = configuration
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return view
    }

    private func pressTab(_ view: NativeTextView) {
        _ = MarkdownLists.handleInsertion(
            textView: view,
            affectedCharRange: view.selectedRange(),
            replacementString: "\t",
            isInsideCodeBlock: false)
    }

    private func leadingTabs(_ view: NativeTextView) -> Int {
        view.string.prefix { $0 == "\t" }.count
    }

    func testDefaultStopsAtTheConfiguredLevel() {
        let view = textView(text: "\t\t\t- item", maximumNestingLevel: nil)
        pressTab(view)
        XCTAssertEqual(leadingTabs(view), 3)
    }

    /// The handler used to read the static default, so an embedder's limit had no effect.
    func testEmbedderLimitIsHonored() {
        let view = textView(text: "- item", maximumNestingLevel: .max)
        for expected in 1...12 {
            pressTab(view)
            XCTAssertEqual(leadingTabs(view), expected)
        }
    }
}
