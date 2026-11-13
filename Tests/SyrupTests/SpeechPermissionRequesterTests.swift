import Dispatch
import Speech
import Testing
@testable import Syrup

@MainActor
struct SpeechPermissionRequesterTests {
    @Test
    func requestAuthorizationCanResumeFromBackgroundQueueWhenCalledOnMainActor() async {
        let status = await SpeechPermissionRequester.requestAuthorization { completion in
            DispatchQueue.global().async {
                completion(.authorized)
            }
        }

        #expect(status == .authorized)
    }
}
