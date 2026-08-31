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
        if evidence.postingFailed || evidence.targetApplicationChanged || evidence.focusedElementChanged {
            return .failed
        }

        if let originalRange = evidence.originalSelection,
           let currentRange = evidence.currentSelection {
            let expectedAdvance = insertedText.utf16.count
            if currentRange.location >= originalRange.location + expectedAdvance {
                return .confirmed
            }
        }

        if let original = evidence.originalValue, let current = evidence.currentValue {
            if current != original, normalized(current).contains(normalized(insertedText)) {
                return .confirmed
            }
            if current == original, rangesEqual(evidence.originalSelection, evidence.currentSelection) {
                return .failed
            }
        }

        return .unavailable
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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

@MainActor
final class TextInsertionSnapshot {
    fileprivate let processIdentifier: pid_t
    fileprivate let focusedElement: AXUIElement
    fileprivate let originalValue: String?
    fileprivate let originalSelection: CFRange?

    fileprivate init(
        processIdentifier: pid_t,
        focusedElement: AXUIElement,
        originalValue: String?,
        originalSelection: CFRange?
    ) {
        self.processIdentifier = processIdentifier
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
              let focusedElement = focusedElement() else { return nil }

        return TextInsertionSnapshot(
            processIdentifier: application.processIdentifier,
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
        let currentElement = focusedElement()
        let focusChanged = currentElement.map { !CFEqual($0, snapshot.focusedElement) } ?? true
        let evidence = InsertionEvidence(
            postingFailed: postingFailed,
            targetApplicationChanged: currentApplication?.processIdentifier != snapshot.processIdentifier,
            focusedElementChanged: focusChanged,
            originalValue: snapshot.originalValue,
            currentValue: stringValue(of: snapshot.focusedElement),
            originalSelection: snapshot.originalSelection,
            currentSelection: selectedRange(of: snapshot.focusedElement)
        )
        return InsertionEvidenceClassifier.classify(evidence, insertedText: insertedText)
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
