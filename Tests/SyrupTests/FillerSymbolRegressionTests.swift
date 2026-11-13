import Foundation
import Testing
@testable import Syrup

@MainActor
struct FillerSymbolRegressionTests {
    @Test(arguments: [
        ("en-US", "done um comma thanks", "done, thanks"),
        ("en-US", "ready uh colon go", "ready: go"),
        ("en-US", "my um underscore variable", "my_variable"),
        ("pt-BR", "e ahn barra ou", "e/ou"),
        ("pt-BR", "olá ahn vírgula mundo", "olá, mundo"),
        ("pt-BR", "bem ahn hífen vindo", "bem-vindo"),
        ("en-US", "and um slash or", "and/or"),
    ])
    func fillersBeforeSymbols(locale: String, input: String, expected: String) {
        #expect(TranscriptCleanup.apply(input, localeID: locale, spokenSymbols: true) == expected)
    }

}
