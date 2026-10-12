import Foundation
import NaturalLanguage

/// A script split into the words the prompter displays, with what the tracker
/// needs to know about each of them.
///
/// Words are split exactly like the prompter view splits them (whitespace, and
/// every CJK character on its own), so a word index here is a word index there,
/// and `charOffset(ofWord:)` matches the view's character offsets in the text
/// collapsed to single spaces.
public struct Script: Sendable {
    public struct Word: Sendable, Equatable {
        /// The word as written, punctuation included.
        public let text: String
        /// Lowercased, without accents or punctuation: what speech is compared to.
        public let key: String
        /// How much a match on this word counts: 0 for cues in [brackets] and
        /// emoji (never spoken), low for short function words, 1 otherwise.
        public let weight: Double
        public let sentence: Int
        public let paragraph: Int
    }

    public let words: [Word]
    /// Index of the first word of each sentence.
    public let sentenceStarts: [Int]
    /// Index of the first word of each paragraph (a new line starts a paragraph).
    public let paragraphStarts: [Int]
    private let offsets: [Int]

    public var isEmpty: Bool { words.isEmpty }
    public var count: Int { words.count }
    /// Length of the text collapsed to single spaces.
    public var characterCount: Int { offsets.last ?? 0 }

    public init(_ text: String) {
        var words: [Word] = []
        var sentenceStarts: [Int] = []
        var paragraphStarts: [Int] = []
        var offsets: [Int] = [0]
        var sentence = -1
        var paragraph = -1
        var inBrackets = false
        var newSentence = true

        for (token, startsLine) in Self.tokens(text) {
            if startsLine || words.isEmpty {
                paragraph += 1
                paragraphStarts.append(words.count)
                newSentence = true
            }
            let opensBrackets = token.hasPrefix("[")
            let isCue = inBrackets || opensBrackets || !token.contains(where: { $0.isLetter || $0.isNumber })
            if opensBrackets { inBrackets = true }
            if token.contains("]") { inBrackets = false }
            if newSentence && !isCue {
                sentence += 1
                sentenceStarts.append(words.count)
                newSentence = false
            }
            let key = Self.key(token)
            words.append(Word(
                text: token,
                key: key,
                weight: isCue ? 0 : Self.weight(key),
                sentence: max(sentence, 0),
                paragraph: paragraph
            ))
            offsets.append(offsets.last! + token.count + 1)
            // "?" alone counts too: French puts a space before it.
            if !inBrackets, !opensBrackets, let last = token.last(where: { !"\"'’»)]*_".contains($0) }), ".!?…".contains(last) {
                newSentence = true
            }
        }
        if offsets.count > 1 { offsets[offsets.count - 1] -= 1 } // no space after the last word
        if sentenceStarts.isEmpty && !words.isEmpty { sentenceStarts = [0] }
        self.words = words
        self.sentenceStarts = sentenceStarts
        self.paragraphStarts = paragraphStarts
        self.offsets = offsets
    }

    // MARK: Positions

    /// Character offset of the start of `word` in the collapsed text (the end of
    /// the text for `count`).
    public func charOffset(ofWord word: Int) -> Int {
        offsets[max(0, min(word, words.count))]
    }

    /// The word that starts at or after `offset`.
    public func word(atCharOffset offset: Int) -> Int {
        var low = 0, high = words.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// First word of the sentence containing `word`.
    public func sentenceStart(at word: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        let sentence = words[min(word, words.count - 1)].sentence
        return sentenceStarts[min(sentence, sentenceStarts.count - 1)]
    }

    /// First word of the paragraph containing `word`.
    public func paragraphStart(at word: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        return paragraphStarts[words[min(word, words.count - 1)].paragraph]
    }

    /// First word of the paragraph before the one containing `word`.
    public func previousParagraphStart(at word: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        let paragraph = words[min(word, words.count - 1)].paragraph
        return paragraphStarts[max(0, paragraph - 1)]
    }

    /// Skips cues and emoji, which are never spoken.
    public func skippingCues(from word: Int) -> Int {
        var index = max(0, word)
        while index < words.count && words[index].weight == 0 { index += 1 }
        return index
    }

    public func sentenceText(_ sentence: Int) -> String {
        guard sentence >= 0, sentence < sentenceStarts.count else { return "" }
        let end = sentence + 1 < sentenceStarts.count ? sentenceStarts[sentence + 1] : words.count
        return words[sentenceStarts[sentence]..<end].filter { $0.weight > 0 }.map(\.text).joined(separator: " ")
    }

    // MARK: Hints for the speech engine

    /// Names and rare words from the script, to help the speech engine spell them.
    public func vocabularyHints(limit: Int = 100) -> [String] {
        var hints: [String] = []
        var seen = Set<String>()
        func add(_ hint: String) {
            let trimmed = hint.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            guard trimmed.count >= 2, seen.insert(trimmed.lowercased()).inserted else { return }
            hints.append(trimmed)
        }
        let text = words.filter { $0.weight > 0 }.map(\.text).joined(separator: " ")
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) { add(String(text[range])) }
            return hints.count < limit
        }
        // Capitalized words inside a sentence are names the tagger may not know.
        let starts = Set(sentenceStarts)
        for (index, word) in words.enumerated() where hints.count < limit {
            guard word.weight == 1, !starts.contains(index),
                  word.text.first?.isUppercase == true else { continue }
            add(word.text)
        }
        return hints
    }

    /// The languages of the script, most used first. A language counts when it
    /// covers at least 15 % of the paragraphs' words; a script in two languages
    /// returns both.
    public func languages() -> [Locale.Language] {
        var counts: [NLLanguage: Int] = [:]
        for (index, start) in paragraphStarts.enumerated() {
            let end = index + 1 < paragraphStarts.count ? paragraphStarts[index + 1] : words.count
            let paragraph = words[start..<end].filter { $0.weight > 0 }
            guard paragraph.count >= 3 else { continue }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(paragraph.map(\.text).joined(separator: " "))
            if let language = recognizer.dominantLanguage { counts[language, default: 0] += paragraph.count }
        }
        let total = max(1, counts.values.reduce(0, +))
        return counts.filter { Double($0.value) / Double(total) >= 0.15 }
            .sorted { $0.value > $1.value }
            .map { Locale.Language(identifier: $0.key.rawValue) }
    }

    // MARK: Words

    /// Lowercased, accents and punctuation removed.
    public static func key(_ word: some StringProtocol) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func weight(_ key: String) -> Double {
        if key.isEmpty { return 0 }
        if functionWords.contains(key) { return 0.3 }
        return key.count <= 3 ? 0.6 : 1
    }

    /// Hesitations dropped from what was heard before matching.
    static let fillers: Set<String> = ["euh", "heu", "hum", "hmm", "mmh", "bah", "ben", "uh", "um", "umm", "erm", "er", "ah", "oh", "hein"]

    /// Short words that appear everywhere in French and English: a match on them
    /// alone says little about where the reader is.
    static let functionWords: Set<String> = [
        "le", "la", "les", "l", "un", "une", "des", "de", "du", "d", "et", "ou", "en", "a", "au", "aux",
        "ce", "ces", "cet", "cette", "c", "se", "sa", "son", "ses", "s", "on", "il", "ils", "elle", "elles",
        "nous", "vous", "je", "j", "tu", "y", "est", "sont", "qui", "que", "qu", "ne", "n", "pas", "plus",
        "pour", "par", "sur", "dans", "avec", "mais", "donc", "car", "si", "ma", "mon", "mes", "ta", "ton",
        "tes", "leur", "leurs", "lui", "me", "m", "te", "t", "cest", "quil", "quon", "lon", "dun", "dune",
        "the", "an", "of", "to", "in", "and", "or", "is", "are", "was", "were", "it", "its", "this", "that",
        "for", "with", "as", "at", "by", "be", "from", "not", "but", "so", "we", "you", "they", "he", "she",
        "i", "my", "your", "our", "their", "than", "then", "there", "if", "do", "does", "did", "have", "has",
        "had", "will", "can", "im", "dont", "thats", "theyre", "youre",
    ]

    /// Same split as the prompter view, plus whether each token starts a line.
    static func tokens(_ text: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var sawNewline = false
        func flush() {
            guard !current.isEmpty else { return }
            var startsLine = sawNewline
            sawNewline = false
            guard current.unicodeScalars.contains(where: \.isCJKIdeograph) else {
                result.append((current, startsLine)); current = ""; return
            }
            var buffer = ""
            for character in current {
                if character.unicodeScalars.first?.isCJKIdeograph == true {
                    if !buffer.isEmpty { result.append((buffer, startsLine)); startsLine = false; buffer = "" }
                    result.append((String(character), startsLine)); startsLine = false
                } else {
                    buffer.append(character)
                }
            }
            if !buffer.isEmpty { result.append((buffer, startsLine)) }
            current = ""
        }
        for character in text {
            if character.isNewline {
                flush(); sawNewline = true
            } else if character.isWhitespace {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return result
    }
}

extension Unicode.Scalar {
    /// Chinese, Japanese and Korean characters, which the prompter shows one by one.
    public var isCJKIdeograph: Bool {
        let v = value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v)
            || (0xAC00...0xD7AF).contains(v)
    }
}
