import Foundation
import Testing
@testable import TakelineCore

@Suite struct ScriptTests {
    @Test func splitsLikeThePrompter() {
        let script = Script("Hello  world.\nSecond line [smile] here 你好")
        #expect(script.words.map(\.text) == ["Hello", "world.", "Second", "line", "[smile]", "here", "你", "好"])
        #expect(script.paragraphStarts == [0, 2])
        #expect(script.sentenceStarts == [0, 2])
        #expect(script.words[4].weight == 0)
        #expect(script.characterCount == "Hello world. Second line [smile] here 你 好".count)
        #expect(script.charOffset(ofWord: 2) == "Hello world. ".count)
        #expect(script.word(atCharOffset: "Hello world. ".count) == 2)
    }

    @Test func keysIgnoreCaseAccentsAndPunctuation() {
        #expect(Script.key("Électriques,") == "electriques")
        #expect(Script.key("l'entretien") == "lentretien")
    }

    @Test func findsNamesAndLanguages() {
        let script = Script(bakery)
        #expect(script.vocabularyHints().contains("Fournil"))
        #expect(script.languages().first == Locale.Language(identifier: "fr"))
        let mixed = Script("Bonjour à tous, aujourd'hui on parle de cuisine et de recettes simples.\nThis part of the video is in English for my international viewers.")
        #expect(Set(mixed.languages().map(\.minimalIdentifier)) == ["fr", "en"])
    }
}

@Suite struct TrackerTests {
    let script = Script(bakery)

    @Test func followsReadingWordByWord() {
        var tracker = Tracker(script: script)
        var heard: [String] = []
        read("Mais comment est-ce qu'ils arrivent à vendre leur pain", with: &tracker, heard: &heard)
        #expect(tracker.position == index(of: "pain", in: script) + 1)
    }

    @Test func toleratesMisheardWords() {
        var tracker = Tracker(script: script)
        var heard: [String] = []
        read("mais comment est ce qu'il arrive à vendre leurs pains aussi peu chère sans perdre d'argent", with: &tracker, heard: &heard)
        #expect(tracker.position >= index(of: "d'argent", in: script))
    }

    @Test func waitsWhileImprovising() {
        var tracker = Tracker(script: script)
        var heard: [String] = []
        read("Mais comment est-ce qu'ils arrivent à vendre leur pain aussi peu cher", with: &tracker, heard: &heard)
        let before = tracker.position
        read("et franchement quand je suis passé à Lyon j'ai été surpris par le nombre de boulangeries dans la rue", with: &tracker, heard: &heard)
        #expect(tracker.position <= before + 4)
        read("sans perdre d'argent", with: &tracker, heard: &heard)
        #expect(tracker.position == index(of: "En réalité", in: script)) // past the "?"
    }

    @Test func jumpsWhenALineIsSkipped() {
        var tracker = Tracker(script: script)
        var heard: [String] = []
        read("Mais comment est-ce qu'ils arrivent à vendre leur pain aussi peu cher, sans perdre d'argent ? En réalité, c'est une vraie leçon d'organisation.", with: &tracker, heard: &heard)
        read("Mais ils sont carrément allés encore plus loin", with: &tracker, heard: &heard)
        #expect(tracker.position == index(of: "allés encore plus loin", in: script) + 4)
    }

    @Test func goesBackWhenASentenceIsReadAgain() {
        var tracker = Tracker(script: script)
        tracker.jump(to: index(of: "Des baguettes super", in: script))
        var heard: [String] = []
        read("Des baguettes super simples à produire, toujours croustillantes et dont la fabrication", with: &tracker, heard: &heard)
        let moves = read("Des baguettes super simples à produire", with: &tracker, heard: &heard)
        let wentBack = moves.contains { $0.isBackward }
        #expect(wentBack)
        #expect(tracker.position == index(of: "produire", in: script) + 1)
    }

    @Test func stepsOverCues() {
        var tracker = Tracker(script: script)
        tracker.jump(to: index(of: "beaucoup moins cher", in: script))
        var heard: [String] = []
        read("beaucoup moins cher.", with: &tracker, heard: &heard)
        #expect(script.words[tracker.position].text == "La")
    }

    @Test func picksTheLanguageThatLinesUp() {
        let mixed = Script("Bonjour à tous et bienvenue sur la chaîne.\nToday we talk about bread recipes in Paris.")
        var tracker = Tracker(script: mixed)
        tracker.jump(to: 8)
        let english = ["today", "we", "talk", "about", "bread"]
        let frenchGuess = ["tout", "de", "oui", "tôt", "bout", "brède"]
        tracker.update(heard: [frenchGuess, english])
        #expect(tracker.position == 13)
    }
}
