import Foundation
import FoundationModels

/// Things the reader can ask out loud.
@Generable
public enum VoiceCommand: String, Sendable, CaseIterable, Codable {
    case previousParagraph, restart, pause, resume, biggerText, smallerText
}

/// What a cue phrase turned out to mean.
public enum Intent: Sendable, Equatable {
    /// Redo the sentence ("on la refait", "take two"…).
    case retake
    case command(VoiceCommand)
}

/// A cue phrase heard outside the script, before anyone decided what it means.
public struct Cue: Sendable, Equatable {
    public let intent: Intent
    /// The words that matched, as heard.
    public let phrase: String
    /// Unambiguous on its own ("on la refait"), as opposed to words that often
    /// mean something else ("attends", "again").
    public let isStrong: Bool
    /// The whole utterance the phrase was heard in.
    public let utterance: [String]
}

/// Spots retake phrases and voice commands, in French and English, in what was
/// just said. Words the script itself contains near the reader are ignored, so
/// reading "on la refait" from the script never triggers anything.
public enum CueSpotter {
    struct Pattern {
        let intent: Intent
        let words: [String]
        let isStrong: Bool
    }

    /// Phrases, most specific first. Several words in a row must all be heard.
    static let patterns: [Pattern] = {
        func p(_ intent: Intent, strong: Bool = true, _ phrases: String...) -> [Pattern] {
            phrases.map { Pattern(intent: intent, words: $0.split(separator: " ").map { Script.key($0) }, isStrong: strong) }
        }
        return p(.retake,
                 "on la refait", "on la refais", "je la refais", "je la refait", "on la reprend", "je la reprends",
                 "je reprends", "je recommence", "on recommence", "on reprend", "je refais", "on refait",
                 "attends non", "attends je reprends", "allez encore", "encore une fois", "une autre prise",
                 "je me suis trompe", "je me suis plante", "pardon je reprends", "coupe on la refait",
                 "take two", "take 2", "take three", "take 3", "another take", "let me start over",
                 "let me try that again", "let me try again", "let me redo that", "let me do that again",
                 "scratch that", "start over", "one more time", "lets do that again", "do that again")
            + p(.command(.previousParagraph),
                "reviens au paragraphe davant", "reviens au paragraphe precedent", "retourne au paragraphe precedent",
                "paragraphe precedent", "paragraphe davant", "remonte dun paragraphe",
                "revenir au paragraphe precedent", "retour au paragraphe precedent",
                "on revient au paragraphe davant", "on revient au paragraphe precedent",
                "go back to the previous paragraph", "back to the previous paragraph", "previous paragraph",
                "go back a paragraph", "back a paragraph", "go back one paragraph", "last paragraph again")
            + p(.command(.restart),
                "reprends au debut", "reprends depuis le debut", "reprends du debut", "on reprend du debut",
                "on reprend au debut", "retour au debut", "reviens au debut", "recommence depuis le debut",
                "start from the top", "from the top", "back to the start", "back to the beginning",
                "start from the beginning", "go back to the beginning", "from the beginning")
            + p(.command(.pause),
                "mets en pause", "fais une pause", "fais pause", "pause", "stop le texte", "arrete le texte",
                "pause please", "stop scrolling", "hold the text")
            + p(.command(.resume),
                "cest reparti", "on continue", "continue", "reprends", "vas y", "resume", "go on", "keep going",
                "carry on")
            + p(.command(.biggerText),
                "texte plus gros", "texte plus grand", "plus gros", "plus grand", "agrandis le texte",
                "grossis le texte", "bigger text", "larger text", "make it bigger", "make the text bigger", "zoom in")
            + p(.command(.smallerText),
                "texte plus petit", "plus petit", "reduis le texte", "rapetisse le texte",
                "smaller text", "make it smaller", "make the text smaller", "zoom out")
            + p(.retake, strong: false,
                "attends", "pardon", "oups", "allez", "encore", "wait", "hold on", "sorry", "oops", "again")
    }()

    /// The cue phrase in `utterance`, if one was said and the script near
    /// `position` doesn't contain it. Resume only counts while paused.
    public static func spot(in utterance: [String], script: Script, position: Int, isPaused: Bool) -> Cue? {
        let heard = utterance.map { Script.key($0) }
        guard !heard.isEmpty else { return nil }
        let nearby = Set(scriptKeys(script, around: position))
        var best: (pattern: Pattern, start: Int)?
        for pattern in patterns {
            if case .command(.resume) = pattern.intent, !isPaused { continue }
            guard let start = find(pattern.words, in: heard) else { continue }
            // Reading the script aloud is not a cue: every word of the phrase
            // would be in the text around the reader.
            if pattern.words.allSatisfy(nearby.contains) { continue }
            // The longest phrase wins: "je reprends au début" is a restart, not "je reprends".
            if best == nil || pattern.words.count > best!.pattern.words.count { best = (pattern, start) }
        }
        guard let best else { return nil }
        let phrase = utterance[best.start..<best.start + best.pattern.words.count].joined(separator: " ")
        return Cue(intent: best.pattern.intent, phrase: phrase, isStrong: best.pattern.isStrong, utterance: utterance)
    }

    /// A strong phrase said on its own, with at most two other words: no need to
    /// ask a model, act right away.
    public static func isClearCut(_ cue: Cue) -> Bool {
        cue.isStrong && cue.utterance.count <= cue.phrase.split(separator: " ").count + 2
    }

    /// Without a language model: a strong phrase said on its own (a command, or
    /// a retake phrase with little else around it) is acted on; anything longer
    /// or weaker is left to the re-read detection.
    public static func decideWithoutModel(_ cue: Cue) -> Intent? {
        guard cue.isStrong else { return nil }
        let phraseLength = cue.phrase.split(separator: " ").count
        let limit = cue.intent == .retake ? phraseLength + 6 : phraseLength + 2
        return cue.utterance.count <= limit ? cue.intent : nil
    }

    static func find(_ phrase: [String], in heard: [String]) -> Int? {
        guard phrase.count <= heard.count else { return nil }
        // The latest occurrence: that's what was just said.
        for start in stride(from: heard.count - phrase.count, through: 0, by: -1)
        where Array(heard[start..<start + phrase.count]) == phrase {
            return start
        }
        return nil
    }

    static func scriptKeys(_ script: Script, around position: Int) -> [String] {
        let low = max(0, position - 40), high = min(script.count, position + 40)
        return script.words[low..<high].map(\.key)
    }
}

/// Asks the on-device Apple model whether a cue phrase was meant for the
/// prompter, using the sentence being read as context.
public actor CueJudge {
    @Generable
    struct Verdict {
        @Guide(description: "retake: the speaker wants to redo what they were saying. command: the speaker is talking to the teleprompter. speech: the words are part of what the speaker is telling their audience.")
        let kind: Kind
        @Guide(description: "The teleprompter command, only when kind is command.")
        let command: VoiceCommand?
    }

    @Generable
    enum Kind { case retake, command, speech }

    public static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    private var session: LanguageModelSession?

    public init() {}

    /// Loads the model ahead of the first question, so the first answer is quick.
    public func prepare() {
        guard Self.isAvailable, session == nil else { return }
        let session = makeSession()
        session.prewarm()
        self.session = session
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: Self.instructions)
    }

    /// The intent, or nil when the words were part of the talk. Throws when the
    /// model is unavailable or fails, so the caller can fall back to rules.
    public func judge(_ cue: Cue, sentence: String, previousSentence: String) async throws -> Intent? {
        // Each question starts from the instructions alone: earlier answers must not sway the next.
        let session = self.session ?? makeSession()
        self.session = nil
        defer { prepare() }
        let prompt = """
            Previous sentence of the script: \(previousSentence)
            Sentence of the script being read: \(sentence)
            What the speaker just said: \(cue.utterance.joined(separator: " "))
            Phrase spotted: \(cue.phrase)
            """
        #if compiler(>=6.4)
        let options = GenerationOptions(samplingMode: .greedy)
        #else
        let options = GenerationOptions(sampling: .greedy)  // the label before the macOS 27 SDK
        #endif
        let verdict = try await session.respond(to: prompt, generating: Verdict.self, options: options).content
        switch verdict.kind {
        case .speech: return nil
        case .retake: return .retake
        case .command:
            if let command = verdict.command { return .command(command) }
            if case .command = cue.intent { return cue.intent }
            return nil
        }
    }

    static let instructions = """
            Someone is recording a video while reading a script on a teleprompter, in French, English or both. \
            Speech recognition heard a phrase that may be meant for the teleprompter rather than the audience. \
            Decide what they meant from the context.
            - retake: they stumbled or want to start the sentence again ("on la refait", "attends, non", "je reprends", "take two", "scratch that", "let me start over").
            - command: they ask the teleprompter to do something: go back to the previous paragraph, restart from the beginning, pause, resume, make the text bigger or smaller.
            - speech: the words belong to what they are telling the audience, for example a story where someone said "on la refait", or a sentence of the script.
            """
}
