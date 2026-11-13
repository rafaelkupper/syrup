import ApplicationServices
import Testing
@testable import Syrup

@MainActor
struct SelectionReaderTests {
    @Test
    func changedForegroundProcessDoesNotReadSelection() async {
        var reads = 0
        let reader = SelectionReader(
            trustStatus: { true }, rawCapture: { reads += 1; return "Unrelated selection" },
            frontmostProcessID: { 102 }
        )
        let result = await reader.captureForRun(processID: 101)
        #expect(result.selection == .sourceChanged)
        #expect(reads == 0)
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
    @Test
    func captureTrimsSelectedText() {
        let reader = SelectionReader(
            trustStatus: { true },
            rawCapture: { "  selected text\n" }
        )

        #expect(reader.capture() == .text("selected text"))
    }

    @Test
    func captureTreatsMissingAndWhitespaceTextAsEmpty() {
        let missingReader = SelectionReader(
            trustStatus: { true },
            rawCapture: { nil }
        )
        let whitespaceReader = SelectionReader(
            trustStatus: { true },
            rawCapture: { " \n\t " }
        )

        #expect(missingReader.capture() == .empty)
        #expect(whitespaceReader.capture() == .empty)
    }

    @Test
    func captureCapsSelectedTextAtTwentyThousandCharacters() {
        let reader = SelectionReader(
            trustStatus: { true },
            rawCapture: { String(repeating: "a", count: 20_001) }
        )

        #expect(reader.capture() == .text(String(repeating: "a", count: 20_000)))
    }

    @Test
    func captureReturnsNotTrustedWithoutReadingSelection() {
        var rawCaptureCallCount = 0
        let reader = SelectionReader(
            trustStatus: { false },
            rawCapture: {
                rawCaptureCallCount += 1
                return "private text"
            }
        )

        #expect(reader.capture() == .notTrusted)
        #expect(rawCaptureCallCount == 0)
    }

    @Test
    func captureDoesNotReadSelectedTextFromSecureField() {
        let focusedElement = AXUIElementCreateSystemWide()
        var requestedAttributes: [String] = []

        let capturedText = SelectionReader.captureSelectedText(
            from: focusedElement,
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

        #expect(capturedText == nil)
        #expect(requestedAttributes.contains(kAXSelectedTextAttribute) == false)
    }
}
