//
//  SpeechRecognizer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Foundation
import TakelineCore
import AVFoundation
import CoreAudio

private let waveformUpdatesPerSecond = 20.0
private let speechCaptureBuffersPerSecond = 40.0

func speechCaptureFormat(for hardwareFormat: AVAudioFormat) -> AVAudioFormat? {
    guard hardwareFormat.channelCount > 1 else { return hardwareFormat }

    // An input-node tap must use the hardware sample rate. AVAudioEngine can
    // downmix channels here, but requesting a different rate raises an
    // uncaught AVFAudio format-mismatch exception on high-rate USB devices.
    return AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: hardwareFormat.sampleRate,
        channels: 1,
        interleaved: false
    )
}

func speechCaptureBufferSize(for format: AVAudioFormat) -> AVAudioFrameCount {
    AVAudioFrameCount(max(1024, format.sampleRate / speechCaptureBuffersPerSecond))
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func allInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = withUnsafeMutablePointer(to: &uid) { uidPointer in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, uidPointer)
            }
            guard uidStatus == noErr else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let nameStatus = withUnsafeMutablePointer(to: &name) { namePointer in
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, namePointer)
            }
            guard nameStatus == noErr else { continue }

            result.append(AudioInputDevice(id: deviceID, uid: uid as String, name: name as String))
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allInputDevices().first(where: { $0.uid == uid })?.id
    }
}


/// Listens to the reader and follows them through the current page. Also runs
/// the auto-scroll of the classic and voice-activated modes, so every view of
/// the prompter (notch, floating window, external display, remote page) shows
/// the same position and the same pause.
///
/// Speech recognition only ever runs on this Mac: when no local engine is
/// available for the language, listening fails with a message instead of
/// sending audio anywhere.
@Observable
class SpeechRecognizer {
    /// Position of word tracking, as a character offset in the page.
    var recognizedCharCount: Int = 0
    var isListening: Bool = false
    var isStarting: Bool = false
    var error: String?
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    var lastSpokenText: String = ""
    var shouldDismiss: Bool = false
    var shouldAdvancePage: Bool = false
    /// Holds the text still in every mode; the microphone stays on so "resume" can be heard.
    var isPaused: Bool = false
    /// The reader is scrolling by hand (classic and voice-activated modes).
    var isUserScrolling: Bool = false
    /// Auto-scroll position in words (classic and voice-activated modes).
    var timerWordProgress: Double = 0
    /// A retake was just noticed: the prompter shows a brief sign.
    var showsRetake: Bool = false
    private var retakeSignGeneration = 0

    /// The reader is on this sentence of the page (word tracking).
    var onReading: ((Int) -> Void)?
    /// The reader redid this sentence of the page.
    var onRetake: ((Int, Session.Retake.Trigger, String?) -> Void)?
    /// A voice command the prompter doesn't handle itself (text size).
    var onCommand: ((VoiceCommand) -> Void)?

    /// Words read and time spent speaking since `resetStatistics`, to learn the reader's pace.
    private(set) var wordsRead = 0
    private(set) var speakingTime: TimeInterval = 0

    func resetStatistics() {
        wordsRead = 0
        speakingTime = 0
    }

    /// True when recent audio levels indicate the user is actively speaking
    var isSpeaking: Bool {
        voiceActivityDetector.isActive(at: ProcessInfo.processInfo.systemUptime)
    }

    /// What the prompter highlights, in every mode.
    var effectiveCharCount: Int {
        NotchSettings.shared.listeningMode == .wordTracking
            ? recognizedCharCount
            : charOffset(forWordProgress: timerWordProgress)
    }

    private(set) var script = Script("")
    private var tracker = Tracker(script: Script(""))
    private var engine: (any SpeechEngine)?
    private var listenTask: Task<Void, Never>?
    /// Per language stream: recent finalized words, the engine's current guess, the utterance so far.
    private var finalized: [[String]] = []
    private var tentative: [[String]] = []
    private var utterance: [[String]] = []
    private var audioEngine = AVAudioEngine()
    private var voiceActivityDetector = VoiceActivityDetector()
    private var configurationChangeObserver: Any?
    private var pendingRestart: DispatchWorkItem?
    private var sessionGeneration: Int = 0
    private var shouldListen: Bool = false
    private var suppressConfigChange: Bool = false
    private var retryCount: Int = 0
    private let maxRetries: Int = 5
    private var scrollTimer: Timer?
    private let judge = CueJudge()
    private var lastSentence = -1

    private var isWordTracking: Bool { NotchSettings.shared.listeningMode == .wordTracking }

    // MARK: Text and position

    /// Update the source text while preserving the current recognized char count.
    /// Used by Director Mode to live-edit unread text without resetting read progress.
    func updateText(_ text: String, preservingCharCount: Int) {
        setScript(text)
        tracker.jump(to: script.word(atCharOffset: min(preservingCharCount, script.characterCount)))
        recognizedCharCount = script.charOffset(ofWord: tracker.position)
    }

    /// Moves the highlight to a character offset (a tap on a word), in every mode.
    func jumpTo(charOffset: Int) {
        if isWordTracking {
            tracker.jump(to: script.word(atCharOffset: charOffset))
            recognizedCharCount = script.charOffset(ofWord: tracker.position)
            lastSentence = -1
        } else {
            timerWordProgress = wordProgress(forCharOffset: charOffset)
        }
    }

    /// The reader scrolled by hand to `progress` (in words).
    func setManualScroll(_ scrolling: Bool, progress: Double) {
        isUserScrolling = scrolling
        if !scrolling {
            timerWordProgress = max(0, min(Double(script.count), progress))
        }
    }

    func charOffset(forWordProgress progress: Double) -> Int {
        let whole = max(0, min(Int(progress), script.count))
        var offset = script.charOffset(ofWord: whole)
        if whole < script.count {
            offset += Int(Double(script.words[whole].text.count) * (progress - Double(whole)))
        }
        return min(offset, script.characterCount)
    }

    func wordProgress(forCharOffset offset: Int) -> Double {
        let word = script.word(atCharOffset: offset)
        guard word > 0 || offset > 0 else { return 0 }
        let start = script.charOffset(ofWord: word)
        if start == offset || word == 0 { return Double(word) }
        // Inside the previous word.
        let previous = word - 1
        let length = max(1, script.words[previous].text.count)
        return Double(previous) + Double(offset - script.charOffset(ofWord: previous)) / Double(length)
    }

    private func setScript(_ text: String) {
        script = Script(text)
        tracker = Tracker(script: script)
        finalized = []
        tentative = []
        utterance = []
        lastSentence = -1
    }

    // MARK: Session

    func start(with text: String) {
        // Clean up any previous session immediately so pending restarts
        // and stale taps are removed before the async permission callback fires.
        cleanupRecognition()
        setScript(text)
        recognizedCharCount = script.charOffset(ofWord: tracker.position)
        timerWordProgress = 0
        isUserScrolling = false
        isPaused = false
        retryCount = 0
        error = nil
        startScrollTimer()
        sessionGeneration &+= 1
        guard NotchSettings.shared.listeningMode != .classic else { return }
        if isWordTracking && NotchSettings.shared.understandContext {
            Task { [judge] in await judge.prepare() }
        }
        shouldListen = true
        isListening = false
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    /// Mutes the microphone (the text stays where it is).
    func stop() {
        shouldListen = false
        sessionGeneration &+= 1
        isListening = false
        isStarting = false
        cleanupRecognition()
    }

    /// Ends the session.
    func forceStop() {
        stop()
        stopScrollTimer()
        setScript("")
        isPaused = false
    }

    /// Unmutes the microphone.
    func resume() {
        guard !script.isEmpty else { return }
        cleanupRecognition()
        retryCount = 0
        shouldDismiss = false
        error = nil
        sessionGeneration &+= 1
        shouldListen = true
        isListening = false
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    // MARK: Auto-scroll

    private func startScrollTimer() {
        stopScrollTimer()
        let interval = 0.05
        scrollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(interval) }
        }
    }

    private func stopScrollTimer() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func tick(_ interval: TimeInterval) {
        if isListening && isSpeaking { speakingTime += interval }
        guard !isPaused, !isUserScrolling, Double(script.count) > timerWordProgress else { return }
        let speed = NotchSettings.shared.scrollSpeed // words per second
        switch NotchSettings.shared.listeningMode {
        case .classic:
            timerWordProgress += speed * interval
        case .silencePaused:
            if isListening && isSpeaking { timerWordProgress += speed * interval }
        case .wordTracking:
            break
        }
    }

    // MARK: Permissions

    private func requestMicrophoneAccessAndBegin(for generation: Int) {
        guard shouldListen, sessionGeneration == generation else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            failListening(String(localized: "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Takeline."))
            openMicrophoneSettings()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.shouldListen, self.sessionGeneration == generation else { return }
                    if granted {
                        self.beginRecognition()
                    } else {
                        self.failListening(String(localized: "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Takeline."))
                    }
                }
            }
        case .authorized:
            beginRecognition()
        @unknown default:
            failListening(String(localized: "Microphone authorization is unavailable."))
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func failListening(_ message: String) {
        voiceActivityDetector.reset()
        shouldListen = false
        isListening = false
        isStarting = false
        error = message
        cleanupRecognition()
    }

    // MARK: Listening

    private func cleanupRecognition() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        listenTask?.cancel()
        listenTask = nil
        if let engine {
            Task { await engine.stop() }
        }
        engine = nil
        voiceActivityDetector.reset()
    }

    /// Coalesces all delayed beginRecognition() calls into a single pending work item.
    private func scheduleBeginRecognition(after delay: TimeInterval) {
        pendingRestart?.cancel()
        guard shouldListen, !script.isEmpty else { return }
        isListening = false
        isStarting = true
        let expectedSessionGeneration = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldListen, self.sessionGeneration == expectedSessionGeneration else { return }
            self.pendingRestart = nil
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func retryOrFail(_ message: String) {
        if retryCount < maxRetries {
            retryCount += 1
            scheduleBeginRecognition(after: 0.5)
        } else {
            failListening(message)
        }
    }

    private func beginRecognition() {
        guard shouldListen, !script.isEmpty else {
            isListening = false
            isStarting = false
            return
        }
        cleanupRecognition()
        let generation = sessionGeneration
        isListening = false
        isStarting = true

        // Create a fresh engine so it picks up the current hardware format.
        // AVAudioEngine caches the device format internally and reset() alone
        // does not reliably flush it after a mic switch.
        audioEngine = AVAudioEngine()
        suppressConfigChange = false

        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID),
           let audioUnit = audioEngine.inputNode.audioUnit {
            // Suppress config-change observer during our own device switch
            suppressConfigChange = true
            var device = deviceID
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            // Re-initialize the audio unit so it picks up the new device's format
            AudioUnitUninitialize(audioUnit)
            AudioUnitInitialize(audioUnit)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.suppressConfigChange = false
            }
        }

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        // Guard against invalid format during device transitions (e.g. mic switch)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            retryOrFail(String(localized: "Audio input is unavailable."))
            return
        }
        guard let tapFormat = speechCaptureFormat(for: hardwareFormat) else {
            failListening(String(localized: "Audio input format is unsupported."))
            return
        }

        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shouldListen, !self.suppressConfigChange, !self.script.isEmpty else { return }
                self.retryCount = 0
                self.cleanupRecognition()
                self.scheduleBeginRecognition(after: 0.5)
            }
        }

        let speechEngine: (any SpeechEngine)? = isWordTracking ? makeEngine() : nil
        engine = speechEngine
        let waveformFrameInterval = AVAudioFrameCount(max(1, tapFormat.sampleRate / waveformUpdatesPerSecond))
        var framesSinceWaveformUpdate = waveformFrameInterval
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: speechCaptureBufferSize(for: tapFormat), format: tapFormat) { [weak self] buffer, _ in
            speechEngine?.append(buffer)

            framesSinceWaveformUpdate &+= buffer.frameLength
            guard framesSinceWaveformUpdate >= waveformFrameInterval else { return }
            framesSinceWaveformUpdate %= waveformFrameInterval
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength { sum += channelData[i] * channelData[i] }
            let level = CGFloat(min(sqrt(sum / Float(max(frameLength, 1))) * 5, 1.0))
            DispatchQueue.main.async {
                guard let self, self.shouldListen, self.sessionGeneration == generation else { return }
                self.recordAudioLevel(level)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            retryOrFail(String(localized: "Audio engine failed: \(error.localizedDescription)"))
            return
        }

        guard let speechEngine else {
            isStarting = false
            isListening = true
            return
        }
        let hints = script.vocabularyHints()
        listenTask = Task { [weak self] in
            guard let self else { return }
            do {
                let locales = await self.locales()
                let stream = try await speechEngine.start(locales: locales, hints: hints, inputFormat: tapFormat)
                guard self.sessionGeneration == generation else { return }
                self.finalized = Array(repeating: [], count: locales.count)
                self.tentative = self.finalized
                self.utterance = self.finalized
                self.isStarting = false
                self.isListening = true
                self.error = nil
                for await heard in stream {
                    guard self.sessionGeneration == generation else { return }
                    self.retryCount = 0
                    self.handle(heard)
                }
            } catch {
                guard self.sessionGeneration == generation else { return }
                // A missing or unsupported language won't fix itself: say so.
                self.failListening(error.localizedDescription)
            }
        }
    }

    private func makeEngine() -> any SpeechEngine {
        AppleSpeechEngine()
    }

    /// The languages to listen for: the script's (two at most) when automatic,
    /// else the one chosen in Settings.
    private func locales() async -> [Locale] {
        let settings = NotchSettings.shared
        guard settings.speechLanguageAutomatic else { return [Locale(identifier: settings.speechLocale)] }
        let languages = script.languages().prefix(2).map { Self.locale(for: $0) }
        return languages.isEmpty ? [Locale(identifier: settings.speechLocale)] : languages
    }

    /// The reader's own variant of a language when they use it (en-GB), else the usual one.
    static func locale(for language: Locale.Language) -> Locale {
        let code = language.languageCode?.identifier ?? "en"
        if let preferred = Locale.preferredLanguages.map(Locale.init(identifier:))
            .first(where: { $0.language.languageCode?.identifier == code && $0.region != nil }) {
            return preferred
        }
        let current = Locale(identifier: NotchSettings.shared.speechLocale)
        if current.language.languageCode?.identifier == code { return current }
        return Locale(identifier: ["en": "en_US", "fr": "fr_FR", "es": "es_ES", "de": "de_DE", "it": "it_IT", "pt": "pt_BR"][code] ?? code)
    }

    private func recordAudioLevel(_ level: CGFloat) {
        audioLevels.append(level)
        if audioLevels.count > 30 {
            audioLevels.removeFirst()
        }
        voiceActivityDetector.process(level: level, at: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: Following the reader

    private func handle(_ heard: Heard) {
        let stream = heard.stream
        guard stream < finalized.count else { return }
        finalized[stream] = Array((finalized[stream] + heard.finalized).suffix(40))
        tentative[stream] = heard.tentative
        utterance[stream] += heard.finalized
        lastSpokenText = (finalized[stream].suffix(8) + tentative[stream]).joined(separator: " ")

        if !isPaused {
            let hypotheses = finalized.indices.map { Array((finalized[$0].suffix(Tracker.heardWindow) + tentative[$0]).suffix(Tracker.heardWindow)) }
            if let move = tracker.update(heard: hypotheses) {
                followed(move)
            }
        }
        if heard.endsUtterance {
            let said = utterance[stream]
            utterance[stream] = []
            spotCues(in: said)
        }
    }

    private func followed(_ move: Tracker.Move) {
        recognizedCharCount = script.charOffset(ofWord: move.to)
        if !move.isBackward {
            wordsRead += min(move.to - move.from, 15)
        } else if NotchSettings.shared.retakeDetection {
            // Reading a passage again is a retake.
            noteRetake(sentence: script.words[min(move.to, script.count - 1)].sentence, trigger: .reread, phrase: nil)
        }
        let sentence = move.to > 0 ? script.words[move.to - 1].sentence : 0
        if sentence != lastSentence {
            lastSentence = sentence
            onReading?(sentence)
        }
    }

    private func noteRetake(sentence: Int, trigger: Session.Retake.Trigger, phrase: String?) {
        showsRetake = true
        retakeSignGeneration &+= 1
        let generation = retakeSignGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.retakeSignGeneration == generation else { return }
            self.showsRetake = false
        }
        onRetake?(sentence, trigger, phrase)
    }

    // MARK: Retakes and voice commands

    private func spotCues(in said: [String]) {
        let settings = NotchSettings.shared
        guard settings.retakeDetection || settings.voiceCommands,
              let cue = CueSpotter.spot(in: said, script: script, position: tracker.position, isPaused: isPaused) else { return }
        switch cue.intent {
        case .retake where !settings.retakeDetection: return
        case .command where !settings.voiceCommands: return
        default: break
        }
        // "On la refait" said on its own needs no second opinion: act at once.
        if CueSpotter.isClearCut(cue) {
            act(on: cue.intent, phrase: cue.phrase)
            return
        }
        guard settings.understandContext, CueJudge.isAvailable else {
            if let intent = CueSpotter.decideWithoutModel(cue) { act(on: intent, phrase: cue.phrase) }
            return
        }
        let sentence = script.words.isEmpty ? 0 : script.words[min(tracker.position, script.count - 1)].sentence
        let current = script.sentenceText(sentence)
        let previous = script.sentenceText(sentence - 1)
        let generation = sessionGeneration
        Task { [weak self, judge] in
            let intent: Intent?
            do {
                intent = try await judge.judge(cue, sentence: current, previousSentence: previous)
            } catch {
                intent = CueSpotter.decideWithoutModel(cue)
            }
            guard let self, self.sessionGeneration == generation, let intent else { return }
            self.act(on: intent, phrase: cue.phrase)
        }
    }

    private func act(on intent: Intent, phrase: String) {
        switch intent {
        case .retake:
            // Back to the start of the sentence being read; right after a
            // sentence ended, the reader means the one they just finished.
            let position = tracker.position
            var start = script.sentenceStart(at: position)
            if position - start <= 1, start > 0 { start = script.sentenceStart(at: start - 1) }
            tracker.jump(to: start)
            recognizedCharCount = script.charOffset(ofWord: tracker.position)
            lastSentence = -1
            noteRetake(sentence: script.words[min(start, script.count - 1)].sentence, trigger: .phrase, phrase: phrase)
        case .command(.previousParagraph):
            jumpToWord(script.previousParagraphStart(at: max(0, tracker.position - 1)))
        case .command(.restart):
            jumpToWord(0)
        case .command(.pause):
            isPaused = true
        case .command(.resume):
            isPaused = false
        case .command(let command):
            onCommand?(command)
        }
    }

    private func jumpToWord(_ word: Int) {
        if isWordTracking {
            tracker.jump(to: word)
            recognizedCharCount = script.charOffset(ofWord: tracker.position)
            lastSentence = -1
        } else {
            timerWordProgress = Double(word)
        }
    }
}
