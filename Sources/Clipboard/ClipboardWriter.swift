import AppKit
import OSLog

enum ClipboardError: Error, Equatable {
    case writeFailed
    /// The write failed and the previous clipboard did not come back: an item with no plain text
    /// (an image or a file), text over the snapshot limit, or a restore the pasteboard refused.
    /// Formatting dropped from an item whose plain text was restored does not count.
    case writeFailedPreviousContentLost
}

@MainActor
protocol PasteboardWriting: AnyObject {
    func write(_ string: String) throws
}

@MainActor
protocol ClipboardPasteboard: AnyObject {
    var pasteboardItems: [NSPasteboardItem]? { get }
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: ClipboardPasteboard {}

@MainActor
final class ClipboardWriter: PasteboardWriting {
    static let defaultSnapshotByteLimit = 1_000_000

    private let pasteboard: any ClipboardPasteboard
    private let snapshotByteLimit: Int

    init(
        pasteboard: any ClipboardPasteboard = NSPasteboard.general,
        snapshotByteLimit: Int = ClipboardWriter.defaultSnapshotByteLimit
    ) {
        self.pasteboard = pasteboard
        self.snapshotByteLimit = snapshotByteLimit
    }

    func write(_ string: String) throws {
        let metrics = ClipboardMetricsRecorder()
        let snapshot = metrics.measure(.snapshot) {
            PasteboardSnapshot.capture(from: pasteboard, byteLimit: snapshotByteLimit)
        }
        _ = pasteboard.clearContents()
        let didWrite = metrics.measure(.writeString) {
            pasteboard.setString(string, forType: .string)
        }
        guard didWrite else {
            let restored = metrics.measure(.restore) {
                snapshot.restore(to: pasteboard)
            }
            throw restored && snapshot.lostItem == false
                ? ClipboardError.writeFailed : ClipboardError.writeFailedPreviousContentLost
        }
    }
}

private struct PasteboardSnapshot {
    let items: [PasteboardItemSnapshot]
    let byteCount: Int
    let didSkipData: Bool
    /// Some item will not come back at all, as opposed to coming back as plain text only.
    let lostItem: Bool

    @MainActor
    static func capture(
        from pasteboard: any ClipboardPasteboard,
        byteLimit: Int
    ) -> PasteboardSnapshot {
        let captureLimit = max(0, byteLimit)
        var byteCount = 0
        var didSkipData = false
        var lostItem = false
        var items: [PasteboardItemSnapshot] = []

        for item in pasteboard.pasteboardItems ?? [] {
            let snapshot = PasteboardItemSnapshot(
                item,
                remainingByteLimit: captureLimit - byteCount
            )

            didSkipData = didSkipData || snapshot.didSkipData
            guard snapshot.values.isEmpty == false else {
                lostItem = lostItem || item.types.isEmpty == false
                continue
            }

            byteCount += snapshot.byteCount
            if byteCount > captureLimit {
                didSkipData = true
                lostItem = true
                items = []
                break
            }

            items.append(snapshot)
        }

        return PasteboardSnapshot(
            items: items,
            byteCount: byteCount,
            didSkipData: didSkipData,
            lostItem: lostItem
        )
    }

    /// Returns false when the pasteboard refused the restored items.
    @MainActor
    func restore(to pasteboard: any ClipboardPasteboard) -> Bool {
        _ = pasteboard.clearContents()
        let restoredItems = items.map(\.pasteboardItem)
        guard restoredItems.isEmpty == false else { return true }
        return pasteboard.writeObjects(restoredItems)
    }
}

private struct PasteboardItemSnapshot {
    let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    let byteCount: Int
    let didSkipData: Bool

    /// Only plain text is captured. Reading other types can ask the source app to render promised
    /// data (an image, a rich document) on every Syrup write, so they are skipped and reported.
    init(_ item: NSPasteboardItem, remainingByteLimit: Int) {
        var byteCount = 0
        var didSkipData = item.types.contains { Self.restorableTypes.contains($0) == false }
        var values: [(type: NSPasteboard.PasteboardType, data: Data)] = []

        for type in Self.restorableTypes where item.types.contains(type) {
            guard let string = item.string(forType: type),
                  let data = string.data(using: .utf8) else {
                continue
            }
            byteCount += data.count
            if byteCount > remainingByteLimit {
                didSkipData = true
                values = []
                break
            }

            values.append((type: type, data: data))
        }

        self.values = values
        self.byteCount = byteCount
        self.didSkipData = didSkipData
    }

    private static let restorableTypes: Set<NSPasteboard.PasteboardType> = [.string]

    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        for value in values {
            _ = item.setData(value.data, forType: value.type)
        }
        return item
    }
}

private enum ClipboardMetricStage: String {
    case snapshot = "pasteboard_snapshot"
    case writeString = "pasteboard_write_string"
    case restore = "pasteboard_restore"
}

private final class ClipboardMetricsRecorder {
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "org.syrup.SyrupApp", category: "Clipboard")
    private let operationID = UUID()

    func measure<Value>(_ stage: ClipboardMetricStage, operation: () throws -> Value) rethrows -> Value {
        let startedAt = clock.now
        do {
            let value = try operation()
            let outcome = (value as? Bool) == false ? "failed" : "success"
            log(stage: stage, startedAt: startedAt, outcome: outcome, value: value)
            return value
        } catch {
            log(stage: stage, startedAt: startedAt, outcome: "failed", value: Optional<PasteboardSnapshot>.none)
            throw error
        }
    }

    private func log<Value>(
        stage: ClipboardMetricStage,
        startedAt: ContinuousClock.Instant,
        outcome: String,
        value: Value
    ) {
        let duration = startedAt.duration(to: clock.now)
        if let snapshot = value as? PasteboardSnapshot {
            logger.info(
                "clipboard_stage=\(stage.rawValue, privacy: .public) operation_id=\(self.operationID.uuidString, privacy: .public) outcome=\(outcome, privacy: .public) duration_ms=\(duration.millisecondsDescription, privacy: .public) snapshot_bytes=\(snapshot.byteCount, privacy: .public) snapshot_skipped_data=\(snapshot.didSkipData, privacy: .public)"
            )
        } else {
            logger.info(
                "clipboard_stage=\(stage.rawValue, privacy: .public) operation_id=\(self.operationID.uuidString, privacy: .public) outcome=\(outcome, privacy: .public) duration_ms=\(duration.millisecondsDescription, privacy: .public)"
            )
        }
    }
}
