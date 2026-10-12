import FoundationModels
import SwiftUI
import TakelineCore

/// Speech recognition, understanding, retakes and voice commands: everything
/// that runs on this Mac to follow the reader.
struct VoiceSettingsView: View {
    @Bindable var settings: NotchSettings

    private enum LanguageState: Equatable {
        case checking, ready, needsDownload, unsupported
        case downloading(Double)
        case failed(String)
    }

    @State private var languageStates: [String: LanguageState] = [:]

    /// The reader's languages and the one picked in Settings, without duplicates.
    private var languages: [Locale] {
        var seen = Set<String>()
        let candidates = Locale.preferredLanguages.prefix(3).map { SpeechRecognizer.locale(for: Locale(identifier: $0).language) }
            + [Locale(identifier: settings.speechLocale)]
            + [Locale(identifier: "fr_FR"), Locale(identifier: "en_US")]
        return candidates.filter { seen.insert($0.language.languageCode?.identifier ?? $0.identifier).inserted }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(
                    String(localized: "Speech recognition"),
                    detail: String(localized: "Apple's recognition, on this Mac only. Your voice never leaves it.")
                ) {
                    ForEach(languages, id: \.identifier) { locale in
                        languageRow(locale)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.speechLanguageAutomatic) {
                        label(String(localized: "Language from the script"),
                              String(localized: "Detects French, English or both in each script. A script that mixes them is followed in both."))
                    }
                    .toggleStyle(.checkbox)

                    if !settings.speechLanguageAutomatic {
                        Picker(String(localized: "Always listen in"), selection: $settings.speechLocale) {
                            ForEach(SpeechLocaleSupport.supportedLocales, id: \.identifier) { locale in
                                Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                    .tag(locale.identifier)
                            }
                        }
                        .padding(.leading, 20)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.retakeDetection) {
                        label(String(localized: "Retakes"),
                              String(localized: "Say \"on la refait\", \"take two\" or read a sentence again: the text goes back to the start of the sentence and the retake is noted."))
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $settings.voiceCommands) {
                        label(String(localized: "Voice commands"),
                              String(localized: "\"Previous paragraph\", \"from the top\", \"pause\", \"bigger text\", in French or English."))
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $settings.understandContext) {
                        label(String(localized: "Understand the context"),
                              understandingDetail)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!settings.retakeDetection && !settings.voiceCommands)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.saveSessions) {
                        label(String(localized: "Save sessions"),
                              String(localized: "At the end of each reading, saves the script and its takes to a file an editing tool such as Roughcut can read."))
                    }
                    .toggleStyle(.checkbox)

                    if settings.saveSessions {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text((settings.sessionsFolder as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(String(localized: "Choose…"), action: chooseSessionsFolder)
                                .controlSize(.small)
                            Button(String(localized: "Show")) {
                                let folder = URL(fileURLWithPath: settings.sessionsFolder, isDirectory: true)
                                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(folder)
                            }
                            .controlSize(.small)
                        }
                        .padding(.leading, 20)
                    }
                }
            }
            .padding(16)
        }
        .task(id: languages.map(\.identifier)) { await refreshLanguages() }
    }

    // MARK: Rows

    private func section(_ title: String, detail: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label(title, detail)
            content()
        }
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func languageRow(_ locale: Locale) -> some View {
        let state = languageStates[locale.identifier] ?? .checking
        return HStack(spacing: 8) {
            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                .font(.system(size: 12))
            Spacer()
            switch state {
            case .checking:
                ProgressView().controlSize(.small)
            case .ready:
                Label(String(localized: "Installed"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            case .needsDownload:
                Button(String(localized: "Install")) { install(locale) }
                    .controlSize(.small)
                    .help(String(localized: "Downloads Apple's speech model for this language, once."))
            case .unsupported:
                Text(String(localized: "Not available on this Mac"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .downloading(let progress):
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: progress).frame(width: 90)
                    if progress == 0 {
                        Text(String(localized: "Waiting for macOS (it holds downloads on metered networks)"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            case .failed(let message):
                Button(String(localized: "Retry")) { install(locale) }
                    .controlSize(.small)
                    .help(message)
            }
        }
        .padding(.vertical, 2)
    }

    private var understandingDetail: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return String(localized: "Apple's on-device model decides whether a phrase was meant for the prompter or for your audience.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Turn on Apple Intelligence in System Settings to use it. Meanwhile, clear phrases and re-reading still work.")
        case .unavailable(.modelNotReady):
            return String(localized: "Apple's model is still downloading. Meanwhile, clear phrases and re-reading still work.")
        default:
            return String(localized: "Not available on this Mac. Clear phrases and re-reading still work.")
        }
    }

    // MARK: Actions

    private func refreshLanguages() async {
        for locale in languages {
            if case .downloading = languageStates[locale.identifier] { continue }
            let status = await AppleSpeechEngine.status(of: locale)
            languageStates[locale.identifier] = switch status {
            case .ready: .ready
            case .needsDownload: .needsDownload
            case .unsupported: .unsupported
            }
        }
    }

    private func install(_ locale: Locale) {
        let id = locale.identifier
        languageStates[id] = .downloading(0)
        Task {
            do {
                try await AppleSpeechEngine.install(locale) { progress in
                    Task { @MainActor in languageStates[id] = .downloading(progress) }
                }
                languageStates[id] = .ready
            } catch {
                languageStates[id] = .failed(error.localizedDescription)
            }
        }
    }

    private func chooseSessionsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.sessionsFolder)
        if panel.runModal() == .OK, let url = panel.url {
            settings.sessionsFolder = url.path
        }
    }
}
