import Testing
@testable import Syrup

struct ModelOutputNormalizerTests {
    @Test(arguments: [
        ("In quotes hello.", true),
        ("Entre aspas bom dia.", true),
        ("Say IN QuOtEs hello.", true),
        ("ÉNTRE ÁSPAS bom dia.", true),
        ("ÍN QUÓTES hello.", true),
        ("(in quotes) hello.", true),
        ("in\nquotes hello.", true),
        ("hello", false),
        ("inquotes hello", false),
        ("within quotes hello", false),
        ("in quotesplease", false),
        ("Abre aspas bom dia fecha aspas", true),
        ("She said open quote done close quote", true),
        ("OPEN QUOTES hello", true),
        ("Send me a quote by Friday", false),
        ("in quotes2", false),
        ("_in quotes", false),
        ("entre aspasx", false),
    ])
    func quoteCommandsMatchWholeWords(input: String, expected: Bool) {
        #expect(ModelOutputNormalizer.requestsQuotes(
            input: input,
            instruction: "Translate.\n" + PromptBuilder.spokenFormattingInstruction
        ) == expected)
    }

    @Test(arguments: ["", "Put the phrase in quotes.", "Translate entre aspas literally."])
    func quoteCommandsRequireSystemFormattingInstruction(instruction: String) {
        #expect(!ModelOutputNormalizer.requestsQuotes(input: "In quotes hello.", instruction: instruction))
        #expect(!ModelOutputNormalizer.requestsQuotes(input: "Entre aspas bom dia.", instruction: instruction))
    }

    @Test(arguments: [
        (#""hello""#, #""hello""#),
        ("  “hello” \n", "“hello”"),
        (" 'hello' ", "'hello'"),
        ("‘hello’", "‘hello’"),
    ])
    func requestedWrapperQuotesAreKept(input: String, expected: String) {
        #expect(ModelOutputNormalizer.normalize(input, keepsWrapperQuotes: true) == expected)
    }

    @Test(arguments: [
        (#""Hello there.""#, "Hello there."),
        (#""say "hello" now""#, #""say "hello" now""#),
        (#""hello" and "goodbye""#, #""hello" and "goodbye""#),
        ("“hello” and “goodbye”", "“hello” and “goodbye”"),
        ("‘hello’ and ‘goodbye’", "‘hello’ and ‘goodbye’"),
        ("'hello' and 'goodbye'", "'hello' and 'goodbye'"),
        (#"He said "hello"."#, #"He said "hello"."#),
    ])
    func defaultNormalizationKeepsExistingInnerQuoteRules(input: String, expected: String) {
        #expect(ModelOutputNormalizer.normalize(input) == expected)
    }
}
