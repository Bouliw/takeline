import SwiftUI

/// Technical settings most people never need.
struct AdvancedSettingsView: View {
    @Bindable var settings: NotchSettings

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Remote view and Director"))
                        .font(.system(size: 13, weight: .medium))
                    Toggle(isOn: $settings.remoteRequiresCode) {
                        detail(String(localized: "Ask for the access code"),
                               String(localized: "The QR code contains it. Without it, anyone who can reach your Mac can read your script, and Director can change it."))
                    }
                    .toggleStyle(.checkbox)
                    Toggle(isOn: $settings.remoteLocalNetworkOnly) {
                        detail(String(localized: "Local network only"),
                               String(localized: "Refuses devices outside your home or office network."))
                    }
                    .toggleStyle(.checkbox)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(String(localized: "Your reading pace"))
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(settings.wordsPerMinute > 0
                             ? String(localized: "\(Int(settings.wordsPerMinute.rounded())) words per minute")
                             : String(localized: "Not learned yet"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if settings.wordsPerMinute > 0 {
                            Button(String(localized: "Reset")) { settings.wordsPerMinute = 0 }
                                .controlSize(.small)
                        }
                    }
                    Text(String(localized: "Learned from your sessions with word tracking, to estimate the length of your videos."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider()

                Toggle(isOn: $settings.checkForUpdates) {
                    detail(String(localized: "Check for updates at launch"),
                           String(localized: "Asks GitHub whether a new version exists. Takeline makes no other network request."))
                }
                .toggleStyle(.checkbox)
            }
            .padding(16)
        }
    }

    private func detail(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
