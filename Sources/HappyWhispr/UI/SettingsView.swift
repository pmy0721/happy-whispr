import SwiftUI
import AppKit

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @State private var apiKeyInput: String = ""
    @State private var isCapturingHotkey: Bool = false
    @State private var selectedTab: SettingsTab = .api
    @State private var showKeySaved: Bool = false
    @State private var keySaveError: String?

    enum SettingsTab: String, CaseIterable, Identifiable {
        case api = "API"
        case shortcuts = "Shortcuts"
        case general = "General"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .api: return "key.fill"
            case .shortcuts: return "command"
            case .general: return "gearshape"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            apiTab
                .tabItem {
                    Label("API", systemImage: "key.fill")
                }
                .tag(SettingsTab.api)

            shortcutsTab
                .tabItem {
                    Label("Shortcuts", systemImage: "command")
                }
                .tag(SettingsTab.shortcuts)

            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
        }
        .frame(width: 500, height: 400)
        .onAppear {
            appState.checkPermissions()
            apiKeyInput = ""
            appState.isApiKeyConfigured = KeychainService.hasApiKey()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkPermissions()
        }
    }

    // MARK: - API Tab

    private var apiTab: some View {
        Form {
            Section {
                HStack {
                    Text("API Key")
                        .frame(width: 100, alignment: .leading)

                    SecureField(appState.isApiKeyConfigured ? "Saved in Keychain" : "sk-or-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)

                    if showKeySaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .help("Saved to Keychain")
                    }
                }

                HStack {
                    Spacer()
                    Button("Save API Key") {
                        saveApiKey()
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let keySaveError {
                    Text(keySaveError)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Text("Get your API key at [openrouter.ai/keys](https://openrouter.ai/keys)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Model")
                        .frame(width: 100, alignment: .leading)

                    Picker("", selection: $appState.selectedModel) {
                        Text("Whisper V3 Turbo").tag("openai/whisper-large-v3-turbo")
                        Text("Whisper V3").tag("openai/whisper-large-v3")
                    }
                    .labelsHidden()
                }

                HStack {
                    Text("Language")
                        .frame(width: 100, alignment: .leading)

                    Picker("", selection: $appState.language) {
                        Text("中文 (zh)").tag("zh")
                        Text("English (en)").tag("en")
                        Text("日本語 (ja)").tag("ja")
                        Text("Auto-detect").tag("auto")
                    }
                    .labelsHidden()
                }
            } header: {
                Text("API")
            }

            Section {
                Button("Delete API Key from Keychain") {
                    KeychainService.deleteApiKey()
                    apiKeyInput = ""
                    appState.isApiKeyConfigured = false
                    showKeySaved = false
                    keySaveError = nil
                }
                .foregroundColor(.red)
            }
        }
        .formStyle(.grouped)
    }

    private func saveApiKey() {
        let trimmedValue = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return }

        keySaveError = nil
        if KeychainService.saveApiKey(trimmedValue) {
            appState.isApiKeyConfigured = true
            showKeySaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showKeySaved = false
            }
        } else {
            appState.isApiKeyConfigured = KeychainService.hasApiKey()
            keySaveError = "Could not save API key to Keychain."
            showKeySaved = false
        }
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        Form {
            Section {
                HStack {
                    Text("Trigger Key")
                        .frame(width: 120, alignment: .leading)

                    Button(action: {
                        isCapturingHotkey = true
                    }) {
                        Text(isCapturingHotkey ? "Press a key..." : "` (backtick)")
                            .frame(width: 120)
                    }
                    .disabled(isCapturingHotkey)
                }

                Text("Hold the backtick key to start recording. Tap it to type a normal backtick.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Trigger")
            }

            Section {
                HStack {
                    Text("Hold Threshold")
                        .frame(width: 120, alignment: .leading)

                    Slider(value: $appState.holdThresholdMs, in: 150...500, step: 10)
                        .frame(width: 200)

                    Text("\(Int(appState.holdThresholdMs))ms")
                        .frame(width: 50, alignment: .trailing)
                        .font(.caption.monospacedDigit())
                }

                Text("How long to hold the key before recording starts. Shorter = faster trigger, longer = fewer accidental activations.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Timing")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $appState.launchAtLogin)
                    .disabled(true)
                    .help("Coming in a later build")

                Toggle("Play sound on paste", isOn: $appState.playSoundOnPaste)
                    .disabled(true)
                    .help("Coming in a later build")

                Toggle("Show error notifications", isOn: $appState.showErrorNotifications)
                    .disabled(true)
                    .help("Coming in a later build")
            } header: {
                Text("Behavior")
            }

            Section {
                HStack {
                    Text("Microphone")
                        .frame(width: 120, alignment: .leading)

                    statusBadge(appState.hasMicrophonePermission)

                    if !appState.hasMicrophonePermission {
                        Button("Request...") {
                            Task {
                                let granted = await AudioCaptureService.requestPermission()
                                await MainActor.run {
                                    appState.hasMicrophonePermission = granted
                                }
                            }
                        }
                    }
                }

                HStack {
                    Text("Accessibility")
                        .frame(width: 120, alignment: .leading)

                    statusBadge(appState.hasAccessibilityPermission)

                    Button("Refresh") {
                        appState.checkPermissions()
                    }

                    if !appState.hasAccessibilityPermission {
                        Button("Open Settings...") {
                            appState.promptForAccessibilityPermission()
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("Permissions")
            }

            Section {
                HStack {
                    Text("Happy Whispr v1.0.0")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("纯 Swift · 零依赖")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func statusBadge(_ granted: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(granted ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(granted ? "Granted" : "Not Granted")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Settings Window Controller

@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func show() {
        appState?.checkPermissions()

        if window == nil {
            let settingsView = SettingsView(appState: appState!)
            let hostingController = NSHostingController(rootView: settingsView)
            hostingController.title = "Happy Whispr Settings"

            window = NSWindow(contentViewController: hostingController)
            window?.title = "Happy Whispr Settings"
            window?.styleMask = [.titled, .closable, .miniaturizable]
            window?.setContentSize(NSSize(width: 500, height: 400))
            window?.center()
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
