import AVFoundation
import Foundation
import Speech

/// What a speech engine heard since its last update, for one language.
public struct Heard: Sendable {
    /// Words the engine won't change any more.
    public var finalized: [String]
    /// The engine's current guess for the words after them; replaced at every update.
    public var tentative: [String]
    /// Which of the languages passed to `start` this is.
    public var stream: Int
    /// The speaker paused: `finalized` closes what they were saying.
    public var endsUtterance: Bool
}

public enum SpeechEngineError: LocalizedError, Sendable {
    case unsupported(Locale)
    case notInstalled(Locale)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unsupported(let locale):
            String(localized: "On-device speech recognition doesn't support \(locale.localizedName) on this Mac.", bundle: .module)
        case .notInstalled(let locale):
            String(localized: "The speech model for \(locale.localizedName) isn't installed yet. Install it in Settings.", bundle: .module)
        case .unavailable:
            String(localized: "On-device speech recognition isn't available on this device.", bundle: .module)
        }
    }
}

/// A speech-to-text engine that runs on the device.
public protocol SpeechEngine: AnyObject, Sendable {
    /// Starts listening in `locales` (one stream per language). `hints` are
    /// names and rare words from the script.
    func start(locales: [Locale], hints: [String], inputFormat: AVAudioFormat) async throws -> AsyncStream<Heard>
    /// Microphone audio in `inputFormat`. Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
    func stop() async
}

extension Locale {
    var localizedName: String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// Apple's speech recognition (SpeechAnalyzer), which only ever runs on the
/// device: audio never leaves it, and when a language isn't available locally
/// the engine says so instead of using a server.
public final class AppleSpeechEngine: SpeechEngine, @unchecked Sendable {
    public enum LanguageStatus: Sendable, Equatable {
        case ready, needsDownload, unsupported
    }

    private struct Stream {
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        let converter: AVAudioConverter?
        let format: AVAudioFormat
        let results: Task<Void, Never>
    }

    private let lock = NSLock()
    private var streams: [Stream] = []
    private var output: AsyncStream<Heard>.Continuation?

    public init() {}

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    public static func status(of locale: Locale) async -> LanguageStatus {
        guard isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return .unsupported }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) } ? .ready : .needsDownload
    }

    /// Downloads Apple's speech model for `locale`. `progress` reports 0…1.
    public static func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw SpeechEngineError.unsupported(locale) }
        let transcriber = Self.transcriber(for: supported)
        _ = try await AssetInventory.reserve(locale: supported)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let observation = request.progress.observe(\.fractionCompleted) { item, _ in progress(item.fractionCompleted) }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    public func start(locales: [Locale], hints: [String], inputFormat: AVAudioFormat) async throws -> AsyncStream<Heard> {
        await stop()
        guard Self.isAvailable else { throw SpeechEngineError.unavailable }
        let (output, continuation) = AsyncStream<Heard>.makeStream()
        var started: [Stream] = []
        do {
            for (index, locale) in locales.enumerated() {
                guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                    throw SpeechEngineError.unsupported(locale)
                }
                guard await Self.status(of: supported) == .ready else { throw SpeechEngineError.notInstalled(supported) }
                let transcriber = Self.transcriber(for: supported)
                let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
                if !hints.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = hints
                    try await analyzer.setContext(context)
                }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    throw SpeechEngineError.unavailable
                }
                let converter = format == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: format)
                let (input, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
                try await analyzer.start(inputSequence: input)
                let results = Task {
                    do {
                        for try await result in transcriber.results {
                            let words = String(result.text.characters).split(whereSeparator: \.isWhitespace).map(String.init)
                            continuation.yield(result.isFinal
                                ? Heard(finalized: words, tentative: [], stream: index, endsUtterance: true)
                                : Heard(finalized: [], tentative: words, stream: index, endsUtterance: false))
                        }
                    } catch {}
                }
                started.append(Stream(analyzer: analyzer, input: inputContinuation, converter: converter, format: format, results: results))
            }
        } catch {
            for stream in started { await Self.finish(stream) }
            continuation.finish()
            throw error
        }
        lock.withLock {
            streams = started
            self.output = continuation
        }
        return output
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        let streams = lock.withLock { self.streams }
        for stream in streams {
            guard let converter = stream.converter else {
                stream.input.yield(AnalyzerInput(buffer: buffer))
                continue
            }
            let ratio = stream.format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: stream.format, frameCapacity: capacity) else { continue }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 { stream.input.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    public func stop() async {
        let (streams, output) = lock.withLock { () -> ([Stream], AsyncStream<Heard>.Continuation?) in
            defer { self.streams = []; self.output = nil }
            return (self.streams, self.output)
        }
        for stream in streams { await Self.finish(stream) }
        output?.finish()
    }

    private static func finish(_ stream: Stream) async {
        stream.input.finish()
        await stream.analyzer.cancelAndFinishNow()
        stream.results.cancel()
    }
}
