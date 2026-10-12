import Foundation

/// What happened while reading a script: every take of every sentence and
/// every retake, timed. Saved as a `.takeline.json` file at the end of a
/// session so an editing tool (Roughcut, for one) can keep the good takes.
///
/// Times are seconds since `startedAt` (the Mac's clock); match them with a
/// camera clip through its creation date, or through the clip's transcript
/// and the sentence texts.
public struct Session: Codable, Sendable, Equatable {
    public struct Sentence: Codable, Sendable, Equatable {
        public let id: Int
        public let page: Int
        public let text: String
    }

    public struct Take: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable {
            /// Read to the end.
            case completed
            /// Stopped by a retake (or a jump back): another take follows.
            case abandoned
            /// The session ended in the middle of it.
            case incomplete
        }
        public let sentence: Int
        public let start: Double
        public var end: Double
        public var status: Status
    }

    public struct Retake: Codable, Sendable, Equatable {
        public enum Trigger: String, Codable, Sendable {
            /// A phrase such as "on la refait" or "take two".
            case phrase
            /// The reader went back and read the sentence again.
            case reread
            /// Both, close together.
            case both
        }
        public let time: Double
        /// The sentence being redone.
        public var sentence: Int
        public var trigger: Trigger
        /// The words heard, for a phrase.
        public var phrase: String?
    }

    public var format = "takeline.session"
    public var version = 1
    public var app: String
    public var title: String
    public var languages: [String]
    public var startedAt: Date
    public var endedAt: Date?
    /// Every sentence of the script, numbered across pages.
    public var sentences: [Sentence]
    public var takes: [Take] = []
    public var retakes: [Retake] = []

    public init(app: String, title: String, pages: [String], languages: [String], startedAt: Date) {
        self.app = app
        self.title = title
        self.languages = languages
        self.startedAt = startedAt
        var sentences: [Sentence] = []
        for (page, text) in pages.enumerated() {
            let script = Script(text)
            for index in script.sentenceStarts.indices {
                sentences.append(Sentence(id: sentences.count, page: page, text: script.sentenceText(index)))
            }
        }
        self.sentences = sentences
    }

    /// Global id of `sentence` on `page`.
    public func sentenceID(page: Int, sentence: Int) -> Int? {
        guard let first = sentences.firstIndex(where: { $0.page == page }) else { return nil }
        let id = first + sentence
        return id < sentences.count && sentences[id].page == page ? id : nil
    }

    // MARK: Recording

    /// The reader is reading `sentence` (a global id) at `date`.
    public mutating func reading(_ sentence: Int, at date: Date) {
        let time = seconds(date)
        if let open = takes.indices.last, takes[open].status == .incomplete {
            guard takes[open].sentence != sentence else { return }
            takes[open].end = time
            takes[open].status = sentence > takes[open].sentence ? .completed : .abandoned
        }
        takes.append(Take(sentence: sentence, start: time, end: time, status: .incomplete))
    }

    /// The reader redid `sentence`. A phrase and a re-read of the same sentence
    /// within 10 seconds are one retake.
    public mutating func retake(_ sentence: Int, trigger: Retake.Trigger, phrase: String? = nil, at date: Date) {
        let time = seconds(date)
        if let last = retakes.indices.last, time - retakes[last].time < 10,
           retakes[last].trigger != trigger, retakes[last].trigger != .both {
            retakes[last].trigger = .both
            retakes[last].sentence = sentence
            retakes[last].phrase = retakes[last].phrase ?? phrase
            return
        }
        if let open = takes.indices.last, takes[open].status == .incomplete {
            takes[open].end = time
            takes[open].status = .abandoned
        }
        retakes.append(Retake(time: time, sentence: sentence, trigger: trigger, phrase: phrase))
    }

    /// Closes the session. `finishedScript` tells whether the reader got to the end.
    public mutating func finish(at date: Date, finishedScript: Bool) {
        endedAt = date
        if let open = takes.indices.last, takes[open].status == .incomplete {
            takes[open].end = seconds(date)
            if finishedScript { takes[open].status = .completed }
        }
    }

    private func seconds(_ date: Date) -> Double {
        (date.timeIntervalSince(startedAt) * 1000).rounded() / 1000
    }

    // MARK: File

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> Session {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Session.self, from: data)
    }
}

/// How long a script takes to read.
public enum ReadingPace {
    /// A typical pace for reading a script aloud, before the reader's own is known.
    public static let defaultWordsPerMinute = 150.0

    /// Words a script has to be read aloud (cues and emoji don't count).
    public static func spokenWords(in text: String) -> Int {
        Script(text).words.count(where: { $0.weight > 0 })
    }

    public static func duration(words: Int, wordsPerMinute: Double) -> TimeInterval {
        Double(words) / max(wordsPerMinute, 1) * 60
    }

    /// Blends a session's pace into the reader's: recent sessions count more,
    /// short ones (under 30 seconds of speech or 50 words) don't count.
    public static func updated(_ wordsPerMinute: Double?, wordsRead: Int, speakingTime: TimeInterval) -> Double? {
        guard wordsRead >= 50, speakingTime >= 30 else { return wordsPerMinute }
        let session = Double(wordsRead) / speakingTime * 60
        guard let wordsPerMinute else { return session }
        return wordsPerMinute * 0.7 + session * 0.3
    }
}
