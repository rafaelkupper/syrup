import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum PasteKeyResolver {
    typealias LayoutMap = [CGKeyCode: String]

    nonisolated static func resolve(
        command: LayoutMap,
        plain: @autoclosure () -> LayoutMap,
        asciiCommand: @autoclosure () -> LayoutMap = [:],
        asciiPlain: @autoclosure () -> LayoutMap = [:]
    ) -> CGKeyCode {
        keyForV(in: command) ?? keyForV(in: plain())
            ?? keyForV(in: asciiCommand()) ?? keyForV(in: asciiPlain())
            ?? CGKeyCode(kVK_ANSI_V)
    }

    @MainActor
    static func currentKeyCode() -> CGKeyCode {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return resolve(
            command: layoutMap(current, modifiers: UInt32(cmdKey >> 8)),
            plain: layoutMap(current, modifiers: 0),
            asciiCommand: layoutMap(
                TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue(),
                modifiers: UInt32(cmdKey >> 8)
            ),
            asciiPlain: layoutMap(
                TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue(),
                modifiers: 0
            )
        )
    }

    nonisolated private static func keyForV(in map: LayoutMap) -> CGKeyCode? {
        map.keys.sorted().first { map[$0]?.lowercased() == "v" }
    }

    @MainActor
    private static func layoutMap(_ source: TISInputSource, modifiers: UInt32) -> LayoutMap {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return [:]
        }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var map: LayoutMap = [:]
        for keyCode in CGKeyCode(0)..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), modifiers,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState, characters.count, &length, &characters
            )
            if status == noErr, length > 0 {
                map[keyCode] = String(utf16CodeUnits: characters, count: length)
            }
        }
        return map
    }
}
