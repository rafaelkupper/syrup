import Foundation
import Testing

struct OwnerBoundaryContractTests {
    /// The in-process DeliveryTarget fake returns the same context for either readsSentence value,
    /// and OSLog delivery depends on the system daemon. Compile the real owners against boundary
    /// doubles to observe these two outgoing requests without Accessibility or the system log store.
    @Test func pasteLastRequestsSentenceContextAndVolumeFailuresLogTheirCode() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scratch = FileManager.default.temporaryDirectory.appending(path: "SyrupOwnerProbe-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let executable = scratch.appending(path: "probe")
        let compilation = try run("/usr/bin/xcrun", [
            "swiftc", "-swift-version", "6", "-parse-as-library",
            root.appending(path: "Sources/App/ResultActions.swift").path,
            root.appending(path: "Sources/App/OutputVolumeChain.swift").path,
            root.appending(path: "Tests/OwnerBoundaryProbe/Doubles.swift").path,
            "-o", executable.path
        ])
        try #require(compilation.status == 0, "\(compilation.output)")
        let probe = try run(executable.path, [])
        try #require(probe.status == 0, "\(probe.output)")
        let report = try #require(JSONSerialization.jsonObject(with: Data(probe.output.utf8)) as? [String: Any])
        #expect(report["sentenceRequests"] as? [Bool] == [true])
        #expect(report["clipboard"] as? [String] == ["Hello."])
        #expect(report["volumeErrors"] as? [String] == ["output_volume_failed error=writeFailed(123)"])
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
