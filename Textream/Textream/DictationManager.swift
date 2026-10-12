//
//  DictationManager.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 26.02.2026.
//

import AppKit
import AVFoundation
import CoreAudio
import Foundation
import TakelineCore

/// Dictation into the script editor, with Apple's on-device speech recognition.
@Observable
class DictationManager {
    var isRecording: Bool = false
    var isStarting: Bool = false
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 40)
    var error: String?

    /// Called on main thread with the latest recognized text for the current segment
    var onTextUpdate: ((String) -> Void)?
    /// Called on main thread when a new recognition segment begins (after a pause)
    var onNewSegment: (() -> Void)?

    private var audioEngine = AVAudioEngine()
    private var engine: AppleSpeechEngine?
    private var listenTask: Task<Void, Never>?
    private var configurationChangeObserver: Any?
    private var shouldRecord = false
    private var sessionGeneration = 0

    func start() {
        guard !isRecording, !isStarting else { return }
        cleanup()
        sessionGeneration &+= 1
        error = nil
        shouldRecord = true
        isStarting = true
        let generation = sessionGeneration
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(generation)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.shouldRecord, self.sessionGeneration == generation else { return }
                    granted ? self.begin(generation) : self.fail(String(localized: "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Takeline."))
                }
            }
        default:
            fail(String(localized: "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Takeline."))
        }
    }

    func stop() {
        shouldRecord = false
        sessionGeneration &+= 1
        isRecording = false
        isStarting = false
        cleanup()
    }

    private func fail(_ message: String) {
        shouldRecord = false
        isRecording = false
        isStarting = false
        error = message
        cleanup()
    }

    private func cleanup() {
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
    }

    private func begin(_ generation: Int) {
        guard shouldRecord, sessionGeneration == generation else { return }
        cleanup()
        audioEngine = AVAudioEngine()

        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID),
           let audioUnit = audioEngine.inputNode.audioUnit {
            var device = deviceID
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            AudioUnitUninitialize(audioUnit)
            AudioUnitInitialize(audioUnit)
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0,
              let tapFormat = speechCaptureFormat(for: recordingFormat) else {
            fail(String(localized: "Audio input is unavailable."))
            return
        }

        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shouldRecord else { return }
                self.isRecording = false
                self.isStarting = true
                self.begin(self.sessionGeneration)
            }
        }

        let engine = AppleSpeechEngine()
        self.engine = engine
        let waveformFrameInterval = AVAudioFrameCount(max(1, tapFormat.sampleRate / 20.0))
        var framesSinceWaveformUpdate = waveformFrameInterval
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: speechCaptureBufferSize(for: tapFormat), format: tapFormat) { [weak self] buffer, _ in
            engine.append(buffer)

            framesSinceWaveformUpdate &+= buffer.frameLength
            guard framesSinceWaveformUpdate >= waveformFrameInterval else { return }
            framesSinceWaveformUpdate %= waveformFrameInterval
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength { sum += channelData[i] * channelData[i] }
            let level = CGFloat(min(sqrt(sum / Float(max(frameLength, 1))) * 5, 1.0))
            DispatchQueue.main.async {
                guard let self else { return }
                self.audioLevels.append(level)
                if self.audioLevels.count > 40 { self.audioLevels.removeFirst() }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            fail(String(localized: "Audio engine failed: \(error.localizedDescription)"))
            return
        }

        let locale = Locale(identifier: NotchSettings.shared.speechLocale)
        listenTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await engine.start(locales: [locale], hints: [], inputFormat: tapFormat)
                guard self.sessionGeneration == generation else { return }
                self.isStarting = false
                self.isRecording = true
                self.onNewSegment?()
                for await heard in stream {
                    guard self.sessionGeneration == generation else { return }
                    if heard.endsUtterance {
                        self.onTextUpdate?(heard.finalized.joined(separator: " "))
                        self.onNewSegment?()
                    } else {
                        self.onTextUpdate?(heard.tentative.joined(separator: " "))
                    }
                }
            } catch {
                guard self.sessionGeneration == generation else { return }
                self.fail(error.localizedDescription)
            }
        }
    }
}
