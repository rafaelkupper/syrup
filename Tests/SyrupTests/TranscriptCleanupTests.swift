import Testing
@testable import Syrup

struct TranscriptCleanupTests {
    @Test(arguments: [
        ("um hello", "en-US", "hello"),
        ("Umm, hello", "en-US", "Hello"),
        ("uh... hello", "en-US", "hello"),
        ("Uhh… hello", "en-US", "Hello"),
        ("erm hello", "en-US", "hello"),
        ("Er, hello", "en-US", "Hello"),
        ("ah hello", "en-US", "hello"),
        ("one um two", "en-US", "one two"),
        ("one, uh, two", "en-US", "one, two"),
        ("Hello. Um, next", "en-US", "Hello. Next"),
        ("um\nuh next", "en-US", "next"),
        ("Hello\nUm, next", "en-US", "Hello\nNext"),
        ("UM UH ER", "en-US", "UM UH ER"),
        ("umbrella ahead error ER uh-huh ahnda", "en-US", "umbrella ahead error ER uh-huh ahnda"),
        ("uhá ãum um_thing uh\u{301}", "en-US", "uhá ãum um_thing uh\u{301}"),
        ("ahn olá", "pt-BR", "olá"),
        ("Hum, olá", "pt-PT", "Olá"),
        ("hmm... olá", "pt-BR", "olá"),
        ("Ãh… olá", "pt-BR", "Olá"),
        ("a\u{303}h, olá", "pt-BR", "olá"),
        ("um tipo é né", "pt-BR", "um tipo é né"),
        ("humano hummus ahnda", "pt-BR", "humano hummus ahnda"),
        ("Um, bonjour", "fr-FR", "Um, bonjour"),
        ("one, new line. two", "en-US", "one\ntwo"),
        ("one LINE BREAK two", "en-US", "one\ntwo"),
        ("one. new paragraph, two", "en-US", "one\n\ntwo"),
        ("open quote hello close quote", "en-US", "\"hello\""),
        ("say, open quote, hello, close quote, now", "en-US", "say \"hello\" now"),
        ("newline new liner", "en-US", "newline new liner"),
        ("one new lineé two", "en-US", "one new lineé two"),
        ("um, one new line Um, two", "en-US", "one\nTwo"),
        ("um...", "en-US", ""),
        ("um\nuh\nhello", "en-US", "hello"),
        ("one\nuh\ntwo", "en-US", "one\n\ntwo"),
        ("one um\ntwo", "en-US", "one\ntwo"),
        ("Um,\nhello", "en-US", "Hello"),
        ("Olá. Hum, tudo bem", "pt-BR", "Olá. Tudo bem"),
        ("um hum\ntexto", "pt-BR", "um\ntexto"),
        ("um abraço", "en-US", "abraço"),
        ("um,", "en-US", ""),
        ("um\n", "en-US", ""),
        ("um", "pt-BR", "um"),
        ("um", "de-DE", "um"),
        ("um hello", "en_US", "hello"),
        ("um hello", "en", "hello"),
        ("um hello", "pt", "um hello"),
        ("olá, nova linha. mundo", "pt-BR", "olá\nmundo"),
        ("olá QUEBRA DE LINHA mundo", "pt-BR", "olá\nmundo"),
        ("olá, NOVO PARÁGRAFO. mundo", "pt-BR", "olá\n\nmundo"),
        ("abre aspas olá fecha aspas", "pt-BR", "\"olá\""),
        ("novo para\u{301}grafo fim", "pt-BR", "fim"),
        ("nova linhaça", "pt-BR", "nova linhaça"),
        ("new line bonjour", "fr-FR", "new line bonjour"),
    ])
    func cleanup(input: String, locale: String, expected: String) {
        #expect(TranscriptCleanup.apply(input, localeID: locale) == expected)
    }

    @Test(arguments: [
        ("So, um, um, new line, thanks.", "So,\nthanks."),
        ("So, um, new line, thanks.", "So,\nthanks."),
        ("Thanks. Ah, um, new paragraph. Best regards.", "Thanks.\n\nBest regards."),
        ("I think, um, ah, new line, we should go.", "I think,\nwe should go."),
        ("um  um new line", ""),
        ("um  um  um", ""),
    ])
    func repeatedFillersBeforeABreakKeepTheBreak(input: String, expected: String) {
        #expect(TranscriptCleanup.apply(input, localeID: "en-US") == expected)
    }
}

struct SpokenSymbolsTests {
    @Test(arguments: [
        ("hashtag release", "en-US", "#release"),
        ("tag it hash sign release", "en-US", "tag it #release"),
        ("mail me at sign home", "en-US", "mail me @home"),
        ("my underscore variable", "en-US", "my_variable"),
        ("well hyphen known", "en-US", "well-known"),
        ("and slash or", "en-US", "and/or"),
        ("done comma thanks", "en-US", "done, thanks"),
        ("one semicolon two colon three", "en-US", "one; two: three"),
        ("Done, Comma, thanks.", "en-US", "Done, thanks."),
        ("a comma comma b", "en-US", "a,, b"),
        ("a comma colon b", "en-US", "a,: b"),
        ("hashtag new line release", "en-US", "#\nrelease"),
        ("hashtag versão", "pt-BR", "#versão"),
        ("jogo da velha versão", "pt-BR", "#versão"),
        ("email sinal de arroba casa", "pt-BR", "email @casa"),
        ("minha sublinhado variável", "pt-BR", "minha_variável"),
        ("bem hífen vindo", "pt-BR", "bem-vindo"),
        ("e barra ou vírgula sim", "pt-BR", "e/ou, sim"),
        ("um ponto e vírgula dois dois pontos três", "pt-BR", "um; dois: três"),
        ("vírgulas barracas hífens colonel commas hashtags", "pt-BR", "vírgulas barracas hífens colonel commas hashtags"),
        ("colonel commas hashtags underscored slashed", "en-US", "colonel commas hashtags underscored slashed"),
        ("éhashtag hashtagé hashtag\u{301} _hashtag hashtag_id", "en-US", "éhashtag hashtagé hashtag\u{301} _hashtag hashtag_id"),
        ("hashtag release", "fr-FR", "hashtag release"),
        ("🙂 hashtag café", "en-US", "🙂 #café"),
    ])
    func symbols(input: String, locale: String, expected: String) {
        #expect(TranscriptCleanup.apply(input, localeID: locale, spokenSymbols: true) == expected)
    }
}
