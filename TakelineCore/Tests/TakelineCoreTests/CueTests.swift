import Foundation
import Testing
@testable import TakelineCore

@Suite struct CueTests {
    let script = Script(bakery)

    func spot(_ said: String, paused: Bool = false) -> Cue? {
        CueSpotter.spot(in: said.split(separator: " ").map(String.init), script: script, position: 20, isPaused: paused)
    }

    @Test func spotsRetakesInBothLanguages() {
        #expect(spot("attends non on la refait")?.intent == .retake)
        #expect(spot("okay take two")?.intent == .retake)
        #expect(spot("scratch that")?.isStrong == true)
        #expect(spot("attends")?.isStrong == false)
    }

    @Test func spotsCommands() {
        #expect(spot("reviens au paragraphe d'avant")?.intent == .command(.previousParagraph))
        #expect(spot("je reprends au début")?.intent == .command(.restart))
        #expect(spot("texte plus gros")?.intent == .command(.biggerText))
        #expect(spot("make it smaller")?.intent == .command(.smallerText))
        #expect(spot("continue") == nil)
        #expect(spot("continue", paused: true)?.intent == .command(.resume))
    }

    @Test func ignoresPhrasesTheScriptContains() {
        let story = Script("Le réalisateur m'a regardé et m'a dit : on la refait, mais cette fois avec le sourire.")
        let cue = CueSpotter.spot(in: ["m'a", "dit", "on", "la", "refait"], script: story, position: 6, isPaused: false)
        #expect(cue == nil)
    }

    @Test func actsAloneOnlyOnShortStrongPhrases() {
        #expect(CueSpotter.decideWithoutModel(spot("on la refait")!) == .retake)
        #expect(CueSpotter.decideWithoutModel(spot("attends")!) == nil)
        let long = spot("et là mon pote me sort qu'il veut le texte plus gros pour lire")!
        #expect(CueSpotter.decideWithoutModel(long) == nil)
    }
}
