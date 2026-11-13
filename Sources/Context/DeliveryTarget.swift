import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Opaque editor identity only. No selected text or field contents are retained.
final class DeliveryTarget: @unchecked Sendable {
    let processID: pid_t
    private let element: AXUIElement?
    private let contextProbe: (@Sendable () async -> CaretContext?)?
    private let checkCurrent: (@MainActor () -> Bool)?
    static let messagingTimeout: Float = 0.1

    init(processID: pid_t, element: AXUIElement) {
        self.processID = processID
        self.element = element
        self.checkCurrent = nil
        self.contextProbe = nil
    }

    init(checkCurrent: @escaping @MainActor () -> Bool, spacingProbe: @escaping @Sendable () async -> Bool = { false }) {
        processID = 0
        element = nil
        self.checkCurrent = checkCurrent
        self.contextProbe = { CaretContext(precedingWordCharacter: await spacingProbe()) }
    }

    init(checkCurrent: @escaping @MainActor () -> Bool, contextProbe: @escaping @Sendable () async -> CaretContext?) {
        processID = 0
        element = nil
        self.checkCurrent = checkCurrent
        self.contextProbe = contextProbe
    }

    @MainActor
    static func capture(processID: pid_t?) async -> DeliveryTarget? {
        guard let processID, AXIsProcessTrusted() else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let element = focusedElement(processID: processID) else { return nil }
            return DeliveryTarget(processID: processID, element: element)
        }.value
    }

    @MainActor
    func isCurrent() -> Bool {
        if let checkCurrent { return checkCurrent() }
        guard let element, NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let focused = Self.focusedElement(processID: processID) else { return false }
        return CFEqual(element, focused)
    }

    @MainActor
    func needsLeadingSpace() async -> Bool {
        await caretContext(readsSentence: false)?.precedingWordCharacter == true
    }

    /// Smart spacing alone reads the one unit before the caret. Caret fit also reads a bounded window
    /// around it: 64 UTF-16 units before and 16 after. Only the derived booleans leave this method.
    @MainActor
    func caretContext(readsSentence: Bool) async -> CaretContext? {
        guard !Task.isCancelled else { return nil }
        if contextProbe == nil {
            guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return nil }
        } else if checkCurrent?() != true { return nil }
        let result = try? await withOperationTimeout(.milliseconds(100), error: CancellationError()) { [self] in
            if let contextProbe { return await contextProbe() }
            let reader = Task.detached(priority: .userInitiated) { [self] () -> CaretContext? in
                guard let element, let focused = Self.focusedElement(processID: processID), CFEqual(element, focused) else { return nil }
                AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
                // Many editors expose no subrole; only a readable secure subrole rejects the field.
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role) == .success,
                   role as? String == kAXSecureTextFieldSubrole as String { return nil }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
                let selection = unsafeBitCast(value, to: AXValue.self)
                var range = CFRange()
                guard AXValueGetType(selection) == .cfRange, AXValueGetValue(selection, .cfRange, &range),
                      range.location >= 0, range.length >= 0, range.length <= Int.max - range.location else { return nil }
                // The character count bounds the read after the caret when the editor reports it. Without it,
                // an unreadable tail means no text follows, so smart spacing keeps working in those editors.
                var countValue: CFTypeRef?
                let count = readsSentence
                    && AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success
                    ? countValue as? Int : nil
                if let count, range.location + range.length > count { return nil }
                let beforeStart = max(0, range.location - (readsSentence ? 64 : 1))
                let afterStart = range.location + range.length
                let afterLength = readsSentence ? count.map { min(16, $0 - afterStart) } ?? 16 : 0
                // Smart spacing used to read one unit; keep that read as the fallback for editors that refuse the window.
                guard let before = Self.read(element, range: CFRange(location: beforeStart, length: range.location - beforeStart))
                        ?? Self.read(element, range: CFRange(location: max(0, range.location - 1), length: min(1, range.location))),
                      !Task.isCancelled else { return nil }
                let after = Self.read(element, range: CFRange(location: afterStart, length: afterLength)) ?? ""
                guard !Task.isCancelled,
                      let current = Self.focusedElement(processID: processID), CFEqual(element, current) else { return nil }
                return CaretContext.parse(before: before, after: after, hasSelection: range.length > 0)
            }
            return await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
        }
        guard !Task.isCancelled else { return nil }
        if contextProbe != nil { return checkCurrent?() == true ? result : nil }
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return nil }
        return result
    }

    private static func read(_ element: AXUIElement, range: CFRange) -> String? {
        guard !Task.isCancelled else { return nil }
        if range.length == 0 { return "" }
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success else { return nil }
        return value as? String
    }

    static func isWordCharacter(_ text: String) -> Bool {
        guard text.utf16.count == 1, let character = text.first else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    private static func focusedElement(processID: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }
}
