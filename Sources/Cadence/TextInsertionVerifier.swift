@preconcurrency import AppKit
import ApplicationServices
import Foundation

enum InsertionVerificationResult: Equatable {
    case confirmed
    case failed
    case unavailable
}

struct InsertionEvidence {
    let postingFailed: Bool
    let targetApplicationChanged: Bool
    let focusedElementChanged: Bool
    let originalValue: String?
    let currentValue: String?
    let originalSelection: CFRange?
    let currentSelection: CFRange?
}

struct InsertionEvidenceClassifier {
    static func classify(_ evidence: InsertionEvidence, insertedText: String) -> InsertionVerificationResult {
        guard !insertedText.isEmpty else { return .confirmed }
        if evidence.postingFailed || evidence.targetApplicationChanged {
            return .failed
        }
        if evidence.focusedElementChanged { return .unavailable }

        // When an editor exposes both its text and selection, require the
        // actual document mutation—not cursor distance alone. Cursor movement
        // can otherwise make a dropped chunk or a newline-to-spaces conversion
        // look successful.
        if let original = evidence.originalValue,
           let current = evidence.currentValue,
           let originalRange = evidence.originalSelection,
           originalRange.location >= 0,
           originalRange.length >= 0,
           originalRange.location + originalRange.length <= original.utf16.count {
            let expected = (original as NSString).replacingCharacters(
                in: NSRange(location: originalRange.location, length: originalRange.length),
                with: insertedText
            )
            if current == expected {
                guard let currentRange = evidence.currentSelection else { return .confirmed }
                let expectedEnd = originalRange.location + insertedText.utf16.count
                return currentRange.location == expectedEnd && currentRange.length == 0
                    ? .confirmed
                    : .failed
            }
            if current != original { return .failed }
        } else if let originalRange = evidence.originalSelection,
                  let currentRange = evidence.currentSelection {
            let expectedAdvance = insertedText.utf16.count
            if currentRange.location >= originalRange.location + expectedAdvance,
               currentRange.length == 0 {
                return .confirmed
            }
        }

        if let original = evidence.originalValue, let current = evidence.currentValue {
            if current == original, rangesEqual(evidence.originalSelection, evidence.currentSelection) {
                return .failed
            }
        }

        return .unavailable
    }

    private static func rangesEqual(_ first: CFRange?, _ second: CFRange?) -> Bool {
        switch (first, second) {
        case let (.some(first), .some(second)):
            first.location == second.location && first.length == second.length
        case (.none, .none):
            true
        default:
            false
        }
    }
}

struct InsertedTextRewriteEvidence {
    let originalValue: String?
    let currentValue: String?
    let originalSelection: CFRange?
    let currentSelection: CFRange?
}

struct InsertedTextRewritePlanner {
    /// Returns the exact UTF-16 range occupied by this dictation only when the
    /// editor still equals the document captured at start with that insertion
    /// applied and the cursor remains at its expected end.
    static func selectionRange(
        for insertedText: String,
        evidence: InsertedTextRewriteEvidence
    ) -> CFRange? {
        guard !insertedText.isEmpty,
              let originalValue = evidence.originalValue,
              let currentValue = evidence.currentValue,
              let originalSelection = evidence.originalSelection,
              let currentSelection = evidence.currentSelection,
              originalSelection.location >= 0,
              originalSelection.length >= 0,
              originalSelection.location + originalSelection.length <= originalValue.utf16.count
        else { return nil }

        let expectedValue = (originalValue as NSString).replacingCharacters(
            in: NSRange(
                location: originalSelection.location,
                length: originalSelection.length
            ),
            with: insertedText
        )
        let expectedEnd = originalSelection.location + insertedText.utf16.count
        guard currentValue == expectedValue,
              currentSelection.location == expectedEnd,
              currentSelection.length == 0 else { return nil }

        return CFRange(
            location: originalSelection.location,
            length: insertedText.utf16.count
        )
    }
}

@MainActor
final class TextInsertionSnapshot {
    fileprivate let processIdentifier: pid_t
    fileprivate let focusedWindow: AXUIElement
    fileprivate let focusedElement: AXUIElement
    fileprivate let originalValue: String?
    fileprivate let originalSelection: CFRange?

    fileprivate init(
        processIdentifier: pid_t,
        focusedWindow: AXUIElement,
        focusedElement: AXUIElement,
        originalValue: String?,
        originalSelection: CFRange?
    ) {
        self.processIdentifier = processIdentifier
        self.focusedWindow = focusedWindow
        self.focusedElement = focusedElement
        self.originalValue = originalValue
        self.originalSelection = originalSelection
    }
}

/// Verifies delivery through the target app's accessibility text state. Quartz
/// event posting has no delivery receipt, so opaque editors intentionally return
/// `.unavailable` instead of producing a misleading recovery warning.
@MainActor
enum TextInsertionVerifier {
    static func capture() -> TextInsertionSnapshot? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let focusedWindow = focusedWindow(processIdentifier: application.processIdentifier),
              let focusedElement = focusedElement() else { return nil }

        return TextInsertionSnapshot(
            processIdentifier: application.processIdentifier,
            focusedWindow: focusedWindow,
            focusedElement: focusedElement,
            originalValue: stringValue(of: focusedElement),
            originalSelection: selectedRange(of: focusedElement)
        )
    }

    static func verify(
        _ snapshot: TextInsertionSnapshot?,
        insertedText: String,
        postingFailed: Bool
    ) -> InsertionVerificationResult {
        guard let snapshot else {
            return postingFailed ? .failed : .unavailable
        }

        let currentApplication = NSWorkspace.shared.frontmostApplication
        let currentWindow = currentApplication.flatMap {
            focusedWindow(processIdentifier: $0.processIdentifier)
        }
        let currentElement = focusedElement()
        let focusChanged = currentElement.map { !CFEqual($0, snapshot.focusedElement) } ?? true
        let windowChanged = currentWindow.map { !CFEqual($0, snapshot.focusedWindow) } ?? true
        let evidence = InsertionEvidence(
            postingFailed: postingFailed,
            targetApplicationChanged: currentApplication?.processIdentifier != snapshot.processIdentifier || windowChanged,
            focusedElementChanged: focusChanged,
            originalValue: snapshot.originalValue,
            currentValue: stringValue(of: snapshot.focusedElement),
            originalSelection: snapshot.originalSelection,
            currentSelection: selectedRange(of: snapshot.focusedElement)
        )
        return InsertionEvidenceClassifier.classify(evidence, insertedText: insertedText)
    }

    static func matchesCurrentTarget(_ snapshot: TextInsertionSnapshot) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processIdentifier,
              let currentWindow = focusedWindow(processIdentifier: snapshot.processIdentifier) else { return false }
        return CFEqual(currentWindow, snapshot.focusedWindow)
    }

    static func currentSelection(_ snapshot: TextInsertionSnapshot) -> CFRange? {
        guard matchesCurrentElement(snapshot) else { return nil }
        return selectedRange(of: snapshot.focusedElement)
    }

    static func selectInsertedText(
        _ snapshot: TextInsertionSnapshot,
        insertedText: String
    ) -> Bool {
        guard matchesCurrentElement(snapshot),
              let selection = InsertedTextRewritePlanner.selectionRange(
                for: insertedText,
                evidence: rewriteEvidence(for: snapshot)
              ),
              setSelection(selection, on: snapshot.focusedElement),
              let selected = selectedRange(of: snapshot.focusedElement)
        else { return false }
        return selected.location == selection.location && selected.length == selection.length
    }

    static func hasExactInsertedText(
        _ snapshot: TextInsertionSnapshot,
        insertedText: String
    ) -> Bool {
        guard matchesCurrentElement(snapshot) else { return false }
        return InsertedTextRewritePlanner.selectionRange(
            for: insertedText,
            evidence: rewriteEvidence(for: snapshot)
        ) != nil
    }

    static func restoreInsertionPoint(
        _ snapshot: TextInsertionSnapshot,
        insertedText: String
    ) -> Bool {
        guard matchesCurrentElement(snapshot),
              let originalValue = snapshot.originalValue,
              let originalSelection = snapshot.originalSelection,
              originalSelection.location >= 0,
              originalSelection.length >= 0,
              originalSelection.location + originalSelection.length <= originalValue.utf16.count
        else { return false }

        let expectedValue = (originalValue as NSString).replacingCharacters(
            in: NSRange(
                location: originalSelection.location,
                length: originalSelection.length
            ),
            with: insertedText
        )
        guard stringValue(of: snapshot.focusedElement) == expectedValue else { return false }
        return setSelection(
            CFRange(
                location: originalSelection.location + insertedText.utf16.count,
                length: 0
            ),
            on: snapshot.focusedElement
        )
    }

    private static func focusedWindow(processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &rawValue
        ) == .success, let rawValue,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else { return nil }
        return (rawValue as! AXUIElement)
    }

    private static func matchesCurrentElement(_ snapshot: TextInsertionSnapshot) -> Bool {
        guard matchesCurrentTarget(snapshot),
              let currentElement = focusedElement() else { return false }
        return CFEqual(currentElement, snapshot.focusedElement)
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &rawValue
        ) == .success, let rawValue else { return nil }
        return (rawValue as! AXUIElement)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &rawValue
        ) == .success else { return nil }
        if let string = rawValue as? String { return string }
        if let attributed = rawValue as? NSAttributedString { return attributed.string }
        return nil
    }

    private static func rewriteEvidence(for snapshot: TextInsertionSnapshot) -> InsertedTextRewriteEvidence {
        InsertedTextRewriteEvidence(
            originalValue: snapshot.originalValue,
            currentValue: stringValue(of: snapshot.focusedElement),
            originalSelection: snapshot.originalSelection,
            currentSelection: selectedRange(of: snapshot.focusedElement)
        )
    }

    private static func setSelection(_ range: CFRange, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else { return false }

        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }

        let axValue = unsafeDowncast(rawValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }
}
