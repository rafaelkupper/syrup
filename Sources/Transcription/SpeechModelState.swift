import Foundation

@MainActor
protocol SpeechModelProviding: AnyObject {
    var state: SpeechModelState { get }
    func loadIfDownloaded()
}

enum SpeechModelState: Equatable, Sendable {
    case unsupported
    case notDownloaded
    case downloading(Double)
    case downloaded
    case loading
    case ready
    case failed(String)

    func fallbackNotice(modelName: String) -> String? {
        switch self {
        case .ready:
            nil
        case .unsupported:
            "\(modelName) needs a Mac with Apple silicon - this dictation used Apple speech recognition."
        case .notDownloaded:
            "\(modelName) isn't downloaded - this dictation used Apple speech recognition. Download it in Settings > Workflows."
        case .downloading:
            "\(modelName) is still downloading - this dictation used Apple speech recognition."
        case .downloaded, .loading:
            "\(modelName) is still loading - this dictation used Apple speech recognition."
        case .failed:
            "\(modelName) isn't available - this dictation used Apple speech recognition. Check Settings > Workflows."
        }
    }
}
