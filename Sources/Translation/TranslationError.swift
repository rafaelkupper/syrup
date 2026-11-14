import Foundation

/// Errors from every `TextTransformer` provider. The name predates workflows; renaming the
/// persisted error domain would be churn with no product value.
enum TranslationError: Error, Equatable, Sendable {
    case missingConfiguration(String)
    case invalidBaseURL(String)
    case invalidResponse
    case emptyResponse
    case outputLimitReached
    case responseFiltered
    case cannotConnect(String)
    case timedOut
    case apiKeyRejected
    case rateLimited
    case httpStatus(Int)
    case codexCLINotFound
    case codexNotSignedIn
    case codexUsageLimit
    case codexEmptyOutput
    case codexFailed(Int)
    case codexTimedOut
    case claudeCLINotFound
    case claudeNotSignedIn
    case claudeUsageLimit
    case claudeEmptyOutput
    case claudeFailed(Int)
    case claudeTimedOut
    case onDeviceUnavailable(String)
    case onDeviceGuardrail
    case onDeviceContextExceeded
}
