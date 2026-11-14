import AppKit
import ApplicationServices
import Foundation

enum SelectionCapture: Equatable, Sendable {
    case text(String)
    case empty
    case notTrusted
    case sourceChanged
}

struct RunSelectionCapture: Sendable {
    let selection: SelectionCapture
    var source: DeliveryTarget? = nil
}

@MainActor
protocol SelectionReading: AnyObject {
    func captureForRun(processID: pid_t?) async -> RunSelectionCapture
}

@MainActor
final class SelectionReader: SelectionReading {
    nonisolated static let maximumCharacterCount = 20_000

    private let trustStatus: () -> Bool
    private let frontmostProcessID: () -> pid_t?
    private let readSelection: @Sendable (pid_t) -> RunSelectionCapture

    init(
        trustStatus: @escaping () -> Bool = { AXIsProcessTrusted() },
        frontmostProcessID: @escaping () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        readSelection: @escaping @Sendable (pid_t) -> RunSelectionCapture = { processID in
            SelectionReader.captureSelection(
                from: AXUIElementCreateApplication(processID),
                processID: processID,
                copyAttribute: SelectionReader.copyAttribute
            )
        }
    ) {
        self.trustStatus = trustStatus
        self.frontmostProcessID = frontmostProcessID
        self.readSelection = readSelection
    }

    /// Reads the triggering app's selection off the main actor, only while that app stays in front.
    func captureForRun(processID: pid_t?) async -> RunSelectionCapture {
        guard trustStatus() else { return RunSelectionCapture(selection: .notTrusted) }
        guard let processID, frontmostProcessID() == processID else {
            return RunSelectionCapture(selection: .sourceChanged)
        }
        let readSelection = readSelection
        let result = await Task.detached(priority: .userInitiated) {
            readSelection(processID)
        }.value
        guard frontmostProcessID() == processID else {
            return RunSelectionCapture(selection: .sourceChanged)
        }
        return result
    }

    nonisolated static func captureSelection(
        from application: AXUIElement,
        processID: pid_t,
        copyAttribute: (CFString, AXUIElement) -> CFTypeRef?
    ) -> RunSelectionCapture {
        guard let element = focusedElement(from: application, copyAttribute: copyAttribute) else {
            return RunSelectionCapture(selection: .empty)
        }
        let text = selectedText(from: element, copyAttribute: copyAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = focusedElement(from: application, copyAttribute: copyAttribute),
              CFEqual(element, current) else {
            return RunSelectionCapture(selection: .sourceChanged)
        }
        let selection: SelectionCapture = if let text, text.isEmpty == false {
            .text(String(text.prefix(maximumCharacterCount)))
        } else {
            .empty
        }
        return RunSelectionCapture(
            selection: selection,
            source: DeliveryTarget(processID: processID, element: element)
        )
    }

    nonisolated private static func focusedElement(
        from application: AXUIElement,
        copyAttribute: (CFString, AXUIElement) -> CFTypeRef?
    ) -> AXUIElement? {
        guard
            let focusedValue = copyAttribute(
                kAXFocusedUIElementAttribute as CFString,
                application
            ),
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeDowncast(focusedValue, to: AXUIElement.self)
    }

    nonisolated private static func selectedText(
        from focusedElement: AXUIElement,
        copyAttribute: (CFString, AXUIElement) -> CFTypeRef?
    ) -> String? {
        if let subroleValue = copyAttribute(
            kAXSubroleAttribute as CFString,
            focusedElement
        ),
            CFGetTypeID(subroleValue) == CFStringGetTypeID(),
            subroleValue as? String == kAXSecureTextFieldSubrole as String
        {
            return nil
        }

        guard
            let selectedTextValue = copyAttribute(
                kAXSelectedTextAttribute as CFString,
                focusedElement
            ),
            CFGetTypeID(selectedTextValue) == CFStringGetTypeID()
        else {
            return nil
        }

        return selectedTextValue as? String
    }

    nonisolated static func copyAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, DeliveryTarget.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }
}
