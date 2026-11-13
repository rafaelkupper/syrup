import Foundation
import Testing
@testable import Syrup

@MainActor
struct PasteStrategyTests {
    @Test(arguments: [
        (["155.0.1.2"], true), (["156.0.8078.76"], true),
        (["157.0.1.2"], false), (["A"], false),
        (["157.0.1.2", "156.0.8078.76"], true),
        (["156.0.1", "156.0.1.2.3", "156.a.1.2", "156..1.2"], false)
    ])
    func choosesStrategyFromFrameworkVersions(versions: [String], typesText: Bool) throws {
        let bundle = try makeBundle(versions: versions)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let strategy = PasteStrategy.resolve(for: bundle, keyCode: 47)
        #expect(strategy == (typesText ? .typeText : .commandV(47)))
    }

    @Test
    func appsWithoutChromiumFrameworkKeepCommandV() throws {
        let bundle = try makeBundle(versions: ["156.0.1.2"], framework: "Other.framework")
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(PasteStrategy.resolve(for: bundle, keyCode: 47) == .commandV(47))
        #expect(PasteStrategy.resolve(for: nil, keyCode: 47) == .commandV(47))
    }

    @Test
    func followsAnInPlaceBrowserUpdateAndKeepsLayoutCurrent() throws {
        let bundle = try makeBundle(versions: ["154.0.1.2"])
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(PasteStrategy.resolve(for: bundle, keyCode: 9) == .commandV(9))
        #expect(PasteStrategy.resolve(for: bundle, keyCode: 47) == .commandV(47))
        let versions = bundle.appendingPathComponent("Contents/Frameworks/Browser Framework.framework/Versions")
        try FileManager.default.createDirectory(at: versions.appendingPathComponent("155.0.1.2"),
            withIntermediateDirectories: true)
        #expect(PasteStrategy.resolve(for: bundle, keyCode: 47) == .typeText)
    }

    @Test
    func versionFilesAreNotTreatedAsVersions() throws {
        let bundle = try makeBundle(versions: ["157.0.1.2"])
        defer { try? FileManager.default.removeItem(at: bundle) }
        let file = bundle.appendingPathComponent("Contents/Frameworks/Browser Framework.framework/Versions/156.0.1.2")
        try Data().write(to: file)
        #expect(PasteStrategy.resolve(for: bundle, keyCode: 9) == .commandV(9))
    }

    private func makeBundle(versions: [String], framework: String = "Browser Framework.framework") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyrupPaste.\(UUID().uuidString).app")
        let base = root.appendingPathComponent("Contents/Frameworks/\(framework)/Versions")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for version in versions {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(version),
                withIntermediateDirectories: true)
        }
        return root
    }
}
