import AppKit
import Testing
@testable import Syrup

@MainActor
struct ClipboardWriterTests {
    @Test
    func writeStoresStringOnInjectedPasteboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let writer = ClipboardWriter(pasteboard: pasteboard)
        try writer.write("Good morning")

        #expect(pasteboard.string(forType: .string) == "Good morning")
    }

    @Test
    func failedWriteRestoresPreviousString() {
        let pasteboard = FakeClipboardPasteboard(
            storedString: "Previous clipboard",
            setResults: [false]
        )
        let writer = ClipboardWriter(pasteboard: pasteboard)

        #expect(throws: ClipboardError.writeFailed) {
            try writer.write("New clipboard")
        }

        #expect(pasteboard.storedString == "Previous clipboard")
        #expect(pasteboard.setStrings == ["New clipboard"])
        #expect(pasteboard.writeObjectCallCount == 1)
    }

    @Test
    func failedWriteDoesNotRestoreUnsupportedNonStringItem() {
        let customType = NSPasteboard.PasteboardType("org.syrup.Syrup.test")
        let data = Data([1, 2, 3, 4])
        let item = NSPasteboardItem()
        _ = item.setData(data, forType: customType)
        let pasteboard = FakeClipboardPasteboard(
            items: [item],
            setResults: [false]
        )
        let writer = ClipboardWriter(pasteboard: pasteboard)

        #expect(throws: ClipboardError.writeFailed) {
            try writer.write("New clipboard")
        }

        #expect(pasteboard.firstItemData(for: customType) == nil)
        #expect(pasteboard.writeObjectCallCount == 0)
    }

    @Test
    func failedWriteRestoresTextFromMixedRichItem() {
        let customType = NSPasteboard.PasteboardType("org.syrup.Syrup.mixed-test")
        let item = NSPasteboardItem()
        _ = item.setString("Previous text", forType: .string)
        _ = item.setData(Data([1, 2, 3, 4]), forType: customType)
        let pasteboard = FakeClipboardPasteboard(
            items: [item],
            setResults: [false]
        )
        let writer = ClipboardWriter(pasteboard: pasteboard, snapshotByteLimit: 64)

        #expect(throws: ClipboardError.writeFailed) {
            try writer.write("New clipboard")
        }

        #expect(pasteboard.storedString == "Previous text")
        #expect(pasteboard.firstItemData(for: customType) == nil)
        #expect(pasteboard.writeObjectCallCount == 1)
    }

    @Test
    func writeDoesNotRequestPromisedRichDataDuringSnapshot() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("org.syrup.Syrup.promised-large-test")
        let provider = CountingPasteboardItemDataProvider(data: Data(repeating: 7, count: 16))
        let item = NSPasteboardItem()
        #expect(item.setDataProvider(provider, forTypes: [customType]))
        #expect(pasteboard.writeObjects([item]))
        #expect(provider.provideCallCount == 0)

        let writer = ClipboardWriter(pasteboard: pasteboard, snapshotByteLimit: 8)

        try writer.write("New clipboard")

        #expect(provider.provideCallCount == 0)
        #expect(pasteboard.string(forType: .string) == "New clipboard")
    }

    @Test
    func failedWriteDoesNotSnapshotLargeUnsupportedExistingPasteboard() {
        let customType = NSPasteboard.PasteboardType("org.syrup.Syrup.large-test")
        let largeData = Data(repeating: 7, count: 16)
        let item = NSPasteboardItem()
        _ = item.setData(largeData, forType: customType)
        let pasteboard = FakeClipboardPasteboard(
            items: [item],
            setResults: [false]
        )
        let writer = ClipboardWriter(pasteboard: pasteboard, snapshotByteLimit: 8)

        #expect(throws: ClipboardError.writeFailed) {
            try writer.write("New clipboard")
        }

        #expect(pasteboard.pasteboardItems?.isEmpty == true)
        #expect(pasteboard.writeObjectCallCount == 0)
    }

    @Test
    func failedWriteDoesNotRestoreOversizedTextSnapshot() {
        let pasteboard = FakeClipboardPasteboard(
            storedString: "This text is too large for the tiny test snapshot limit.",
            setResults: [false]
        )
        let writer = ClipboardWriter(pasteboard: pasteboard, snapshotByteLimit: 8)

        #expect(throws: ClipboardError.writeFailed) {
            try writer.write("New clipboard")
        }

        #expect(pasteboard.pasteboardItems?.isEmpty == true)
        #expect(pasteboard.writeObjectCallCount == 0)
    }

    @Test
    func failedWriteRestoresTextWhenExistingPasteboardIsWithinSnapshotLimit() {
        let pasteboard = FakeClipboardPasteboard(
            storedString: "Small previous text",
            setResults: [false]
        )
        let writer = ClipboardWriter(pasteboard: pasteboard, snapshotByteLimit: 64)

        #expect(throws: ClipboardError.writeFailed) {
            try writer.write("New clipboard")
        }

        #expect(pasteboard.storedString == "Small previous text")
        #expect(pasteboard.writeObjectCallCount == 1)
    }
}

@MainActor
private final class FakeClipboardPasteboard: ClipboardPasteboard {
    var pasteboardItems: [NSPasteboardItem]?
    private(set) var setStrings: [String] = []
    private(set) var writeObjectCallCount = 0
    private var setResults: [Bool]

    init(storedString: String?, setResults: [Bool]) {
        let item = NSPasteboardItem()
        if let storedString {
            _ = item.setString(storedString, forType: .string)
            self.pasteboardItems = [item]
        } else {
            self.pasteboardItems = []
        }
        self.setResults = setResults
    }

    init(items: [NSPasteboardItem], setResults: [Bool]) {
        self.pasteboardItems = items
        self.setResults = setResults
    }

    var storedString: String? {
        pasteboardItems?.first?.string(forType: .string)
    }

    func clearContents() -> Int {
        pasteboardItems = []
        return 1
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        setStrings.append(string)
        let result = setResults.isEmpty ? true : setResults.removeFirst()
        if result {
            let item = NSPasteboardItem()
            _ = item.setString(string, forType: dataType)
            pasteboardItems = [item]
        }
        return result
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        writeObjectCallCount += 1
        pasteboardItems = objects.compactMap { object in
            guard let item = object as? NSPasteboardItem else { return nil }
            return Self.copy(item)
        }
        return true
    }

    func firstItemData(for type: NSPasteboard.PasteboardType) -> Data? {
        pasteboardItems?.first?.data(forType: type)
    }

    private static func copy(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let copiedItem = NSPasteboardItem()
        for type in item.types {
            guard let data = item.data(forType: type) else { continue }
            _ = copiedItem.setData(data, forType: type)
        }
        return copiedItem
    }
}

private final class CountingPasteboardItemDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let data: Data
    private let lock = NSLock()
    private var count = 0

    init(data: Data) {
        self.data = data
    }

    var provideCallCount: Int {
        lock.withLock {
            count
        }
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.withLock {
            count += 1
        }
        item.setData(data, forType: type)
    }
}
