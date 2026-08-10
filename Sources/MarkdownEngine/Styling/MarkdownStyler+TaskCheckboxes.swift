//
//  MarkdownStyler+TaskCheckboxes.swift
//  MarkdownEngine
//
//  Caret-crossing helper for GitHub-style `- [ ] / - [x]` task syntax. The
//  checkbox *styling* now lives in the AST styler (`MarkdownASTStyler`); this
//  only reports whether the caret sits inside the task syntax so the
//  coordinator can trigger a restyle when the caret enters/leaves.
//

import AppKit
import Foundation

extension MarkdownStyler {

    /// Task-list line: indent, marker (`-`/`*`/`+`/`•`/`N.` matching the AST), spacer, `[ ]`/`[x]` box.
    static let taskListRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-•*+]|\d+\.)([ \t]+)(\[[ xX]\])(?=[ \t])"#,
        options: [.anchorsMatchLines]
    )

    /// Notes also accept a checkbox without a bullet. The line-boundary lookahead
    /// keeps `[text](url)` and ordinary incomplete-link syntax as prose.
    static let bareTaskListRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)(\[(?:[ xX])?\])(?=[ \t\r\n]|$)"#,
        options: [.anchorsMatchLines]
    )

    // MARK: Task Syntax Membership

    /// Full task syntax range if `location` is inside (or at its trailing edge), else nil.
    static func taskSyntaxRange(at location: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        let safeLoc = max(0, min(location, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let line = nsText.substring(with: lineRange)
        if let match = taskListRegex.firstMatch(
            in: line,
            options: [],
            range: NSRange(location: 0, length: line.utf16.count)
        ) {
            let markerLineRange = match.range(at: 2)
            let checkboxLineRange = match.range(at: 4)
            guard markerLineRange.location != NSNotFound,
                  checkboxLineRange.location != NSNotFound else { return nil }
            let syntaxStart = lineRange.location + markerLineRange.location
            let syntaxEnd = lineRange.location + checkboxLineRange.location + checkboxLineRange.length
            let syntaxRange = NSRange(location: syntaxStart, length: syntaxEnd - syntaxStart)
            if NSLocationInRange(location, syntaxRange) || location == syntaxEnd {
                return syntaxRange
            }
            return nil
        }

        guard let match = bareTaskListRegex.firstMatch(
            in: line,
            options: [],
            range: NSRange(location: 0, length: line.utf16.count)
        ) else { return nil }
        let checkboxLineRange = match.range(at: 2)
        guard checkboxLineRange.location != NSNotFound else { return nil }
        let syntaxStart = lineRange.location + checkboxLineRange.location
        let syntaxRange = NSRange(location: syntaxStart, length: checkboxLineRange.length)
        if NSLocationInRange(location, syntaxRange) || location == NSMaxRange(syntaxRange) {
            return syntaxRange
        }
        return nil
    }
}
