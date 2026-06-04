import Foundation
import Combine
import ApplicationServices

// MARK: - App Lifecycle State

enum AppPhase: Equatable {
    case idle
    case pending                          // backtick keyDown, waiting 200ms to distinguish tap vs hold
    case recording                        // hold confirmed, actively recording audio
    case transcribing                     // keyUp received, sending audio to STT API
    case error(AppError)
}

// MARK: - App Error

enum AppError: Error, Equatable {
    case noMicrophonePermission
    case noAccessibilityPermission
    case apiKeyNotSet
    case apiKeyInvalid
    case transcriptionTimeout
    case transcriptionFailed(String)
    case eventTapInterrupted
    case recordingTooLong

    var localizedDescription: String {
        switch self {
        case .noMicrophonePermission:
            return "Microphone permission required"
        case .noAccessibilityPermission:
            return "Accessibility permission required"
        case .apiKeyNotSet:
            return "API key not configured"
        case .apiKeyInvalid:
            return "API key invalid (401)"
        case .transcriptionTimeout:
            return "Transcription timed out"
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        case .eventTapInterrupted:
            return "Keyboard monitor interrupted"
        case .recordingTooLong:
            return "Recording exceeded 30s limit"
        }
    }
}

// MARK: - App State (ObservableObject)

@MainActor
final class AppState: ObservableObject {

    private enum DefaultsKey {
        static let holdThresholdMs = "holdThresholdMs"
        static let selectedModel = "selectedModel"
        static let language = "language"
        static let launchAtLogin = "launchAtLogin"
        static let playSoundOnPaste = "playSoundOnPaste"
        static let showErrorNotifications = "showErrorNotifications"
    }

    private static let defaultHoldThresholdMs: Double = 200
    private static let defaultModel = "openai/whisper-large-v3-turbo"
    private static let defaultLanguage = "zh"

    // MARK: Published State

    @Published var phase: AppPhase = .idle
    @Published var currentTranscript: String = ""
    @Published var rmsPower: Float = 0.0
    @Published var hasMicrophonePermission: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    @Published var isApiKeyConfigured: Bool = false

    // MARK: Settings (stored in UserDefaults)

    @Published var holdThresholdMs: Double {
        didSet {
            UserDefaults.standard.set(holdThresholdMs, forKey: DefaultsKey.holdThresholdMs)
            keyboardMonitor.holdThresholdMs = holdThresholdMs
        }
    }
    @Published var selectedModel: String {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: DefaultsKey.selectedModel)
        }
    }
    @Published var language: String {
        didSet {
            UserDefaults.standard.set(language, forKey: DefaultsKey.language)
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: DefaultsKey.launchAtLogin)
        }
    }
    @Published var playSoundOnPaste: Bool {
        didSet {
            UserDefaults.standard.set(playSoundOnPaste, forKey: DefaultsKey.playSoundOnPaste)
        }
    }
    @Published var showErrorNotifications: Bool {
        didSet {
            UserDefaults.standard.set(showErrorNotifications, forKey: DefaultsKey.showErrorNotifications)
        }
    }

    // MARK: Services

    let keyboardMonitor = KeyboardMonitor()
    let audioCapture = AudioCaptureService()
    let sttService = STTService()
    let pasteService = PasteService()

    private var cancellables = Set<AnyCancellable>()
    private var previousKeyboardPhase: KeyboardPhase = .idle
    private var shouldSkipNextRecordingCompletion = false

    init() {
        let defaults = UserDefaults.standard
        holdThresholdMs = defaults.object(forKey: DefaultsKey.holdThresholdMs) as? Double ?? Self.defaultHoldThresholdMs
        selectedModel = defaults.string(forKey: DefaultsKey.selectedModel) ?? Self.defaultModel
        language = defaults.string(forKey: DefaultsKey.language) ?? Self.defaultLanguage
        launchAtLogin = defaults.bool(forKey: DefaultsKey.launchAtLogin)
        playSoundOnPaste = defaults.bool(forKey: DefaultsKey.playSoundOnPaste)
        showErrorNotifications = defaults.object(forKey: DefaultsKey.showErrorNotifications) as? Bool ?? true

        keyboardMonitor.holdThresholdMs = holdThresholdMs
        audioCapture.onMaxDurationExceeded = { [weak self] in
            Task { @MainActor in
                self?.handleRecordingTimeout()
            }
        }
        setupBindings()
    }

    // MARK: - Bindings

    private func setupBindings() {
        // Keyboard monitor phase changes → trigger app actions
        keyboardMonitor.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] newPhase in
                guard let self = self else { return }
                let prev = self.previousKeyboardPhase
                self.previousKeyboardPhase = newPhase

                switch (prev, newPhase) {
                case (.recording, .idle):
                    guard !self.shouldSkipNextRecordingCompletion else {
                        self.shouldSkipNextRecordingCompletion = false
                        return
                    }
                    // Recording finished — stop capture and transcribe
                    self.phase = .transcribing
                    self.handleRecordingComplete()
                case (.pending, .recording):
                    // Hold confirmed — start recording
                    self.startRecording()
                case (.pending, .idle):
                    // Key released before hold threshold — normal tap, just reset
                    self.phase = .idle
                case (_, .idle):
                    self.phase = .idle
                case (_, .pending):
                    self.phase = .pending
                case (_, .recording):
                    // Already handled above
                    break
                }
            }
            .store(in: &cancellables)

        // Audio RMS power
        audioCapture.$rmsPower
            .receive(on: RunLoop.main)
            .sink { [weak self] power in
                self?.rmsPower = power
            }
            .store(in: &cancellables)

        // STT transcript
        sttService.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.currentTranscript = text
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    func startRecording() {
        guard hasMicrophonePermission else {
            shouldSkipNextRecordingCompletion = true
            showError(.noMicrophonePermission)
            keyboardMonitor.stop()
            keyboardMonitor.start()
            return
        }
        phase = .recording
        audioCapture.startCapture()
    }

    private func handleRecordingComplete() {
        audioCapture.stopCapture()

        Task {
            do {
                guard !audioCapture.wavBuffer.isEmpty else {
                    await MainActor.run { self.phase = .idle }
                    return
                }

                let text = try await sttService.transcribe(
                    audioData: audioCapture.wavBuffer,
                    model: selectedModel,
                    language: language
                )
                await MainActor.run {
                    self.currentTranscript = text
                    if !text.isEmpty {
                        self.pasteService.paste(text: text)
                    }
                    self.phase = .idle
                }
            } catch {
                await MainActor.run {
                    if let appError = error as? AppError {
                        self.showError(appError)
                    } else {
                        self.showError(.transcriptionFailed(error.localizedDescription))
                    }
                }
            }
        }
    }

    private func handleRecordingTimeout() {
        shouldSkipNextRecordingCompletion = true
        showError(.recordingTooLong)
        keyboardMonitor.stop()
        keyboardMonitor.start()
    }

    private func showError(_ error: AppError) {
        phase = .error(error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            if case .error = self.phase {
                self.phase = .idle
            }
        }
    }

    func cancelRecording() {
        audioCapture.stopCapture()
        keyboardMonitor.stop()
        phase = .idle
    }

    func checkPermissions() {
        let microphonePermission = AudioCaptureService.checkPermission()
        let accessibilityPermission = AXIsProcessTrusted()
        let apiKeyConfigured = KeychainService.hasApiKey()

        if hasMicrophonePermission != microphonePermission {
            hasMicrophonePermission = microphonePermission
        }
        if hasAccessibilityPermission != accessibilityPermission {
            hasAccessibilityPermission = accessibilityPermission
        }
        if isApiKeyConfigured != apiKeyConfigured {
            isApiKeyConfigured = apiKeyConfigured
        }
    }

    func promptForAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let accessibilityPermission = AXIsProcessTrustedWithOptions(options)

        if hasAccessibilityPermission != accessibilityPermission {
            hasAccessibilityPermission = accessibilityPermission
        }
    }

    func configureKeyboardMonitor() {
        keyboardMonitor.start()
    }
}
