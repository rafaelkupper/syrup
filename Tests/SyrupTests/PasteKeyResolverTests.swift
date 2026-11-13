import Carbon.HIToolbox
import Testing
@testable import Syrup

struct PasteKeyResolverTests {
    @Test(arguments: [
        ([UInt16(9): "v", 47: "."], [UInt16(9): "v", 47: "."], UInt16(9)),
        ([UInt16(9): "k", 47: "v"], [UInt16(9): "k", 47: "v"], UInt16(47)),
        ([UInt16(9): "v", 47: "."], [UInt16(9): "k", 47: "v"], UInt16(9)),
        ([UInt16(9): "м", 47: "ю"], [UInt16(9): "м", 47: "ю"], UInt16(9))
    ])
    func resolvesQwertyDvorakCommandDvorakAndCyrillic(
        command: [UInt16: String], plain: [UInt16: String], expected: UInt16
    ) {
        #expect(PasteKeyResolver.resolve(command: command, plain: plain,
            asciiCommand: [9: "v"], asciiPlain: [9: "v"]) == expected)
    }

    @Test
    func plainLayerPrecedesAsciiFallback() {
        #expect(PasteKeyResolver.resolve(command: [9: "k"], plain: [47: "v"],
            asciiCommand: [9: "v"]) == 47)
    }

    @Test
    func asciiLayoutAndPhysicalKeyAreLastResorts() {
        #expect(PasteKeyResolver.resolve(command: [:], plain: [:], asciiPlain: [47: "V"]) == 47)
        #expect(PasteKeyResolver.resolve(command: [:], plain: [:]) == UInt16(kVK_ANSI_V))
    }
}
