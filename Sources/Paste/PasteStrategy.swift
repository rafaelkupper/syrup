import CoreGraphics
import Foundation

enum PasteStrategy: Equatable, Sendable {
    case commandV(CGKeyCode)
    case typeText

    nonisolated static func choose(versionNames: [String], keyCode: CGKeyCode) -> PasteStrategy {
        // Remove this workaround when Chromium 157 is the minimum supported version.
        let needsTyping = versionNames.contains { name in
            let components = name.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 4,
                  components.allSatisfy({ part in
                      part.isEmpty == false && part.utf8.allSatisfy { (48...57).contains($0) }
                  }),
                  let major = Int(components[0]) else { return false }
            return major == 155 || major == 156
        }
        return needsTyping ? .typeText : .commandV(keyCode)
    }

    nonisolated static func resolve(for bundleURL: URL?, keyCode: CGKeyCode) -> PasteStrategy {
        guard let bundleURL else { return .commandV(keyCode) }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: frameworks, includingPropertiesForKeys: nil
        )) ?? []
        let versionNames = children.filter { $0.lastPathComponent.hasSuffix("Framework.framework") }
            .flatMap { framework in
                let versions = framework.appendingPathComponent("Versions", isDirectory: true)
                return (try? FileManager.default.contentsOfDirectory(
                    at: versions, includingPropertiesForKeys: [.isDirectoryKey]
                ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .map(\.lastPathComponent) ?? []
            }
        return choose(versionNames: versionNames, keyCode: keyCode)
    }
}
