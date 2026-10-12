import Foundation

/// Follows the reader through the script from what the speech engine heard.
///
/// Each update aligns the last words heard with the script (a local alignment,
/// like a spell-checker's, that tolerates misheard, missing and extra words)
/// and compares "the reader moved there" with "the reader is still here".
/// It moves only when the evidence is strong enough for the size of the move:
/// - reading on: one word that lines up is enough;
/// - a skipped line: about three words, confirmed by the next word read;
/// - going back to re-read: the same;
/// - improvising: nothing lines up, so the position waits.
public struct Tracker: Sendable {
    public struct Move: Sendable, Equatable {
        public let from: Int
        public let to: Int
        public var isBackward: Bool { to < from }
    }

    public let script: Script
    /// Index of the next word to read; `script.count` once everything is read.
    public private(set) var position: Int
    private var pendingTarget: Int?

    /// How many of the last words heard are aligned: enough to recognize a
    /// passage, few enough that what was read a while ago doesn't hold the
    /// position once the reader has moved.
    static let heardWindow = 8
    static let gapHeard = 1.0

    public init(script: Script, position: Int = 0) {
        self.script = script
        self.position = script.skippingCues(from: position)
    }

    /// Moves to `word` (a tap on the text, a voice command, a retake).
    public mutating func jump(to word: Int) {
        position = script.skippingCues(from: min(max(0, word), script.count))
        pendingTarget = nil
    }

    /// Feeds what the engine heard, oldest word first. With several hypotheses
    /// (one per language when the script mixes two), the one that lines up best
    /// wins. Returns the move made, if any.
    @discardableResult
    public mutating func update(heard hypotheses: [[String]]) -> Move? {
        var best: (target: Int, score: Double, gain: Double)?
        for heard in hypotheses {
            let keys = heard.map { Script.key($0) }
                .filter { !$0.isEmpty && !Script.fillers.contains($0) }
                .suffix(Self.heardWindow)
            guard let candidate = bestMove(for: Array(keys)) else { continue }
            if best == nil || candidate.score > best!.score { best = candidate }
        }
        guard let best else { return nil }
        let delta = best.target - position
        // A step back of a word or two is a revised word, not a re-read.
        guard delta > 0 || delta < -2 else { return nil }

        // Moving on must beat staying put, so a chance match while improvising
        // doesn't drag the reader forward. Big moves need more words instead.
        switch delta {
        case 1...4: guard best.score >= 0.95, best.gain >= 1 else { return nil }
        case 5...15: guard best.score >= 1.8, best.gain >= 1 else { return nil }
        default: guard best.score >= 2.6 else { return nil }
        }

        if delta > 15 || delta < -2 {
            // The next word read must land just after the first guess, so one
            // stray match can't throw the reader to another part of the script.
            guard let pendingTarget, best.target > pendingTarget, best.target <= pendingTarget + 4 else {
                pendingTarget = best.target
                return nil
            }
        }
        pendingTarget = nil
        let move = Move(from: position, to: script.skippingCues(from: best.target))
        position = move.to
        return move
    }

    /// The best place for the reader after `heard`, its score (roughly the
    /// number of words that line up, function words counting for less, minus a
    /// penalty for moving far) and how much better it is than staying put.
    func bestMove(for heard: [String]) -> (target: Int, score: Double, gain: Double)? {
        guard !heard.isEmpty, !script.isEmpty else { return nil }
        let scores = alignmentScores(heard)
        var best: (target: Int, score: Double)?
        for target in 1..<scores.count {
            let score = scores[target] - distancePenalty(target - position)
            if score > 0, best == nil || score > best!.score { best = (target, score) }
        }
        guard let best else { return nil }
        return (best.target, best.score, best.score - max(0, scores[position]))
    }

    func distancePenalty(_ delta: Int) -> Double {
        switch delta {
        case -2...15: 0
        case 16...: min(1, 0.01 * Double(delta - 15))
        default: min(1.5, 0.4 + 0.01 * Double(-delta))
        }
    }

    /// For each script position, the best score of an alignment of all of
    /// `heard` (up to its last word) that ends there.
    func alignmentScores(_ heard: [String]) -> [Double] {
        let words = script.words
        let columns = words.count
        var older = [Double](repeating: 0, count: columns + 1)
        var previous = older
        var current = older
        for (i, word) in heard.enumerated() {
            current[0] = 0
            for column in 1...columns {
                let scriptWord = words[column - 1]
                var score = max(0, previous[column] - Self.gapHeard)
                if scriptWord.weight == 0 {
                    // Cues are never spoken: step over them for free.
                    current[column] = max(score, current[column - 1])
                    continue
                }
                let similarity = Self.similarity(word, scriptWord.key)
                if similarity > 0 {
                    score = max(score, previous[column - 1] + scriptWord.weight * similarity)
                }
                // Words heard split ("est ce" for "est-ce") or merged ("ridehailing" for "ride-hailing").
                if i > 0, Self.isSameWord(heard[i - 1] + word, scriptWord.key) {
                    score = max(score, older[column - 1] + scriptWord.weight)
                }
                if column > 1, words[column - 2].weight > 0,
                   Self.isSameWord(word, words[column - 2].key + scriptWord.key) {
                    score = max(score, previous[column - 2] + max(words[column - 2].weight, scriptWord.weight))
                }
                // A script word not heard (missed by the engine, or skipped).
                score = max(score, current[column - 1] - (0.15 + 0.3 * scriptWord.weight))
                current[column] = score
            }
            (older, previous, current) = (previous, current, older)
        }
        return previous
    }

    /// 1 for the same word, a little less for a near miss (plural, conjugation,
    /// one letter misheard), 0 otherwise. Words of one or two letters must be exact.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let shorter = min(a.count, b.count)
        guard shorter >= 3 else { return 0 }
        let sharedPrefix = zip(a, b).prefix { $0 == $1 }.count
        if sharedPrefix >= 4 && sharedPrefix >= shorter - 1 { return 0.9 }
        let ratio = 1 - Double(editDistance(a, b)) / Double(max(a.count, b.count))
        return ratio >= 0.7 ? ratio : 0
    }

    /// Words joined together must match exactly: a near miss proves nothing
    /// there ("économiques" + "à" is one letter away from "économiques").
    static func isSameWord(_ a: String, _ b: String) -> Bool { a == b }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = a[i - 1] == b[j - 1] ? diagonal : min(diagonal, above, row[j - 1]) + 1
                diagonal = above
            }
        }
        return row[b.count]
    }
}
