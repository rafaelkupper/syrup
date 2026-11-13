import Foundation
import Testing
@testable import Syrup

struct SuccessSoundTests {
    @Test
    func everyCaseMapsToAnInstalledSystemSound() {
        let soundsDirectory = URL(filePath: "/System/Library/Sounds", directoryHint: .isDirectory)
        for sound in SuccessSound.allCases {
            #expect(sound.systemSoundName.isEmpty == false)
            #expect(sound.displayName.isEmpty == false)

            let file = soundsDirectory
                .appending(path: sound.systemSoundName)
                .appendingPathExtension("aiff")
            #expect(
                FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
                "missing system sound for \(sound.rawValue): \(sound.systemSoundName)"
            )
        }
    }

    @Test
    func defaultChimePreservesLegacyGlassSound() {
        #expect(SuccessSound.default == .chime)
        #expect(SuccessSound.chime.systemSoundName == "Glass")
    }

    @Test
    func rawValuesRoundTrip() {
        for sound in SuccessSound.allCases {
            #expect(SuccessSound(rawValue: sound.rawValue) == sound)
        }
    }
}
