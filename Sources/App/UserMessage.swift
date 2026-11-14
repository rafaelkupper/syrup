import Foundation

enum PipelineError: Error, Equatable {
    case emptyTranscript
    case noSelectedText
    case selectionAccessibilityRequired
    case selectionSourceChanged
    case streamingFailed(String)
}

/// The one place typed errors from every module become the single line a person sees.
/// Never include raw error descriptions: they can carry paths or user content.
func userMessage(for error: Error) -> String {
    if let secretError = error as? KeychainStoreError {
        return switch secretError {
        case .readFailed: "The saved API key could not be read. Check access to Syrup's local secret store."
        case .saveFailed: "API key could not be saved"
        case .deleteFailed: "API key could not be removed"
        }
    }
    if let audioError = error as? AudioRecordingError {
        switch audioError {
        case .microphoneAccessDenied:
            return "Microphone access denied - enable Syrup in System Settings > Privacy & Security > Microphone."
        case .builtInMicrophoneUnavailableWithClosedLid: return "The built-in microphone is off while the lid is closed. Connect or select another microphone."
        case .microphoneStartFailed:
            return "Microphone could not start"
        case .audioBufferOverflow:
            return "Audio processing could not keep up. Try a shorter dictation."
        }
    }

    if let pipelineError = error as? PipelineError {
        switch pipelineError {
        case .emptyTranscript:
            return "Nothing heard"
        case .noSelectedText:
            return "No text selected"
        case .selectionAccessibilityRequired:
            return "Accessibility access required - grant Syrup access in System Settings > Privacy & Security > Accessibility."
        case .selectionSourceChanged:
            return "The selected editor changed - select the text and try again."
        case .streamingFailed(let message):
            return "\(message) - partial text may remain in the target app"
        }
    }

    if let transcriptionError = error as? TranscriptionError {
        switch transcriptionError {
        case .speechRecognitionAccessDenied:
            return "Speech recognition access denied - enable Syrup in System Settings > Privacy & Security > Speech Recognition."
        case .speechRecognitionRestricted:
            return "Speech recognition is restricted on this Mac"
        case .speechTranscriberUnavailable:
            return "On-device transcription is not available on this Mac"
        case .localeNotSupported(let languageName):
            return "\(languageName) is not supported for on-device transcription"
        case .languageModelInstalling(let languageName):
            return "\(languageName) language model is downloading - open Settings to see progress."
        case .languageModelUnavailable(let languageName):
            return "\(languageName) language model could not be installed"
        case .noCompatibleAudioFormat:
            return "Speech recognition could not use the microphone audio format"
        case .finalizationTimedOut:
            return "Speech recognition timed out. Please try again."
        case .audioConversionFailed:
            return "Audio could not be prepared for speech recognition"
        }
    }

    if let translationError = error as? TranslationError {
        switch translationError {
        case .missingConfiguration:
            return "Translation endpoint is not configured"
        case .invalidBaseURL:
            return "Translation endpoint URL is invalid"
        case .invalidResponse:
            return "Translation endpoint returned an invalid response"
        case .emptyResponse:
            return "Translation was empty"
        case .outputLimitReached:
            return "The model stopped before finishing - try a shorter input or another model."
        case .responseFiltered:
            return "The model declined part of this content - the result was not delivered."
        case .cannotConnect(let host):
            return "Can't reach \(host)"
        case .timedOut:
            return "Translation timed out"
        case .apiKeyRejected:
            return "API key rejected"
        case .rateLimited:
            return "Rate limited"
        case .httpStatus(let statusCode):
            return "Translation endpoint returned HTTP \(statusCode)"
        case .codexCLINotFound:
            return "Codex CLI not found - install it or set its path in Settings"
        case .codexNotSignedIn:
            return "Codex isn't signed in - run `codex login` in Terminal"
        case .codexUsageLimit:
            return "Codex usage limit reached - try later or switch provider"
        case .codexEmptyOutput:
            return "Codex returned no output"
        case .codexFailed(let exitCode):
            return "Codex failed (exit \(exitCode))"
        case .codexTimedOut:
            return "Codex timed out"
        case .onDeviceUnavailable(let reason):
            return reason
        case .onDeviceGuardrail:
            return "The on-device model declined this content - transcript kept"
        case .onDeviceContextExceeded:
            return "Dictation too long for the on-device model - switch provider or dictate in shorter parts"
        }
    }

    if let clipboardError = error as? ClipboardError {
        switch clipboardError {
        case .writeFailed:
            return "Clipboard could not be written"
        case .writeFailedPreviousContentLost:
            return "Clipboard could not be written, and what it held before could not be restored"
        }
    }

    if error is CancellationError {
        return "Canceled"
    }

    return "Something went wrong"
}
