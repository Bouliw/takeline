import Foundation
import Testing
@testable import TakelineCore

@Suite struct SessionTests {
    @Test func recordsTakesAndRetakes() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var session = Session(app: "Takeline 1.0", title: "Bakery", pages: [bakery], languages: ["fr"], startedAt: start)
        #expect(session.sentences.count == 8)
        session.reading(0, at: start.addingTimeInterval(1))
        session.reading(1, at: start.addingTimeInterval(9))
        session.retake(1, trigger: .phrase, phrase: "on la refait", at: start.addingTimeInterval(12))
        session.retake(1, trigger: .reread, at: start.addingTimeInterval(14))
        session.reading(1, at: start.addingTimeInterval(14))
        session.reading(2, at: start.addingTimeInterval(20))
        session.finish(at: start.addingTimeInterval(25), finishedScript: false)

        #expect(session.takes.map(\.status) == [.completed, .abandoned, .completed, .incomplete])
        #expect(session.takes[1].end == 12)
        #expect(session.retakes.count == 1)
        #expect(session.retakes[0].trigger == .both)
        #expect(session.retakes[0].phrase == "on la refait")

        let data = try session.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"started_at\""))
        let decoded = try Session.decoded(from: data)
        #expect(decoded == session)
    }

    @Test func endsTakesOnJumpsBackAndKeepsLateRetakesApart() {
        let start = Date(timeIntervalSince1970: 1_000)
        var session = Session(app: "", title: "", pages: [bakery], languages: [], startedAt: start)
        session.reading(2, at: start)
        session.reading(1, at: start.addingTimeInterval(5))
        session.retake(1, trigger: .phrase, at: start.addingTimeInterval(6))
        session.retake(1, trigger: .reread, at: start.addingTimeInterval(20))
        session.reading(1, at: start.addingTimeInterval(20))
        session.finish(at: start.addingTimeInterval(30), finishedScript: true)

        #expect(session.takes.map(\.status) == [.abandoned, .abandoned, .completed])
        #expect(session.retakes.map(\.trigger) == [.phrase, .reread])
    }

    /// Editors such as Roughcut read session files as docs/session-format.md describes them.
    @Test func writesTheDocumentedFormat() throws {
        let doc = try String(contentsOf: URL(filePath: "../../../docs/session-format.md", relativeTo: URL(filePath: #filePath)), encoding: .utf8)
        let example = Data(try #require(doc.components(separatedBy: "```json\n").dropFirst().first?.components(separatedBy: "```").first).utf8)
        let session = try Session.decoded(from: example)
        #expect(session.format == "takeline.session" && session.version == 1)
        let written = try JSONSerialization.jsonObject(with: session.encoded()) as? NSDictionary
        #expect(written == (try JSONSerialization.jsonObject(with: example) as? NSDictionary))
    }

    @Test func numbersSentencesAcrossPages() {
        let session = Session(app: "", title: "", pages: ["One. Two.", "Three."], languages: [], startedAt: .now)
        #expect(session.sentenceID(page: 1, sentence: 0) == 2)
        #expect(session.sentenceID(page: 1, sentence: 1) == nil)
    }

    @Test func learnsTheReadersPace() {
        #expect(ReadingPace.spokenWords(in: "Hello [pause] world 🙂") == 2)
        #expect(ReadingPace.duration(words: 300, wordsPerMinute: 150) == 120)
        #expect(ReadingPace.updated(nil, wordsRead: 20, speakingTime: 10) == nil)
        #expect(ReadingPace.updated(nil, wordsRead: 180, speakingTime: 60) == 180)
        #expect(abs(ReadingPace.updated(150, wordsRead: 180, speakingTime: 60)! - 159) < 0.001)
    }
}
