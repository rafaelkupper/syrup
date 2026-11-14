import Foundation
import ApplicationServices
import Testing
@testable import Syrup

@MainActor
struct SelectionReaderTests {
    @Test
    func changedForegroundProcessDoesNotReadSelection() async {
        let reads = ReadCounter()
        let reader = SelectionReader(
            trustStatus: { true }, frontmostProcessID: { 102 },
            readSelection: { _ in reads.increment(); return RunSelectionCapture(selection: .text("Unrelated selection")) }
        )
        let result = await reader.captureForRun(processID: 101)
        #expect(result.selection == .sourceChanged)
        #expect(reads.count == 0)
    }

    @Test
    func untrustedReaderReturnsNotTrustedWithoutReading() async {
        let reads = ReadCounter()
        let reader = SelectionReader(
            trustStatus: { false }, frontmostProcessID: { 101 },
            readSelection: { _ in reads.increment(); return RunSelectionCapture(selection: .text("private text")) }
        )
        #expect(await reader.captureForRun(processID: 101).selection == .notTrusted)
        #expect(reads.count == 0)
    }

    @Test
    func fieldChangeDuringSelectionReadDiscardsTextAndIdentity() {
        let application = AXUIElementCreateApplication(101)
        let original = AXUIElementCreateApplication(101)
        let replacement = AXUIElementCreateApplication(102)
        var focusReads = 0
        let result = SelectionReader.captureSelection(
            from: application, processID: 101,
            copyAttribute: { attribute, _ in
                switch attribute as String {
                case kAXFocusedUIElementAttribute:
                    focusReads += 1
                    return focusReads == 1 ? original : replacement
                case kAXSelectedTextAttribute: return "Original selection" as CFString
                default: return nil
                }
            }
        )
        #expect(result.selection == .sourceChanged)
        #expect(result.source == nil)
    }

    @Test
    func validatedSelectionRetainsItsSourceAndCharacterCap() {
        let application = AXUIElementCreateApplication(101)
        let result = SelectionReader.captureSelection(
            from: application, processID: 101,
            copyAttribute: { attribute, _ in
                switch attribute as String {
                case kAXFocusedUIElementAttribute: return application
                case kAXSelectedTextAttribute: return ("  " + String(repeating: "a", count: 20_001)) as CFString
                default: return nil
                }
            }
        )
        #expect(result.selection == .text(String(repeating: "a", count: 20_000)))
        #expect(result.source?.processID == 101)
    }
    @Test(arguments: [nil, " \n\t "] as [String?])
    func missingOrWhitespaceSelectionIsEmpty(selected: String?) {
        let application = AXUIElementCreateApplication(101)
        let result = SelectionReader.captureSelection(
            from: application, processID: 101,
            copyAttribute: { attribute, _ in
                switch attribute as String {
                case kAXFocusedUIElementAttribute: return application
                case kAXSelectedTextAttribute: return selected.map { $0 as CFString }
                default: return nil
                }
            }
        )
        #expect(result.selection == .empty)
    }

    @Test
    func captureDoesNotReadSelectedTextFromSecureField() {
        let focusedElement = AXUIElementCreateApplication(101)
        var requestedAttributes: [String] = []

        let captured = SelectionReader.captureSelection(
            from: focusedElement, processID: 101,
            copyAttribute: { attribute, _ in
                let attributeName = attribute as String
                requestedAttributes.append(attributeName)

                switch attributeName {
                case kAXFocusedUIElementAttribute:
                    return focusedElement
                case kAXSubroleAttribute:
                    return kAXSecureTextFieldSubrole as CFString
                case kAXSelectedTextAttribute:
                    return "private text" as CFString
                default:
                    return nil
                }
            }
        )

        #expect(captured.selection == .empty)
        #expect(requestedAttributes.contains(kAXSelectedTextAttribute) == false)
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
