import SwiftUI
import AppKit

// MARK: - Menu Bar View

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @State private var showSettings = false

    var body: some View {
        // This view is hosted in NSStatusBarButton via NSHostingView
        // The actual rendering is the status item icon; this serves as the menu content
        EmptyView()
    }

    // MARK: - Status Bar Icon Helpers

    static func statusBarIcon() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
        let pixelsWide = Int(size.width * scale)
        let pixelsHigh = Int(size.height * scale)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(systemSymbolName: "waveform", accessibilityDescription: "Happy Whispr")
                ?? NSImage(size: size)
        }

        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.black.setFill()

        let barWidth: CGFloat = 1.9
        let cornerRadius: CGFloat = 0.95
        let bars: [(x: CGFloat, height: CGFloat)] = [
            (3.8, 7.5),
            (7.4, 12.0),
            (11.0, 17.0),
            (14.6, 12.0),
            (18.2, 7.5),
        ]

        for bar in bars {
            let rect = NSRect(
                x: bar.x - barWidth / 2,
                y: (size.height - bar.height) / 2,
                width: barWidth,
                height: bar.height
            )
            NSBezierPath(
                roundedRect: rect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }

    static func iconColor(for phase: AppPhase) -> NSColor {
        switch phase {
        case .idle:
            return .controlTextColor
        case .pending:
            return .controlTextColor
        case .recording:
            return .systemGreen
        case .transcribing:
            return .systemBlue
        case .error(let error):
            switch error {
            case .noAccessibilityPermission, .eventTapInterrupted:
                return .systemOrange
            case .apiKeyNotSet, .apiKeyInvalid:
                return .systemYellow
            case .noMicrophonePermission:
                return .systemGray
            default:
                return .systemRed
            }
        }
    }

    // MARK: - Menu Builder

    static func buildMenu(appState: AppState, showSettings: Binding<Bool>, quitAction: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()

        // Status indicator
        let statusItem = NSMenuItem(
            title: statusText(for: appState.phase),
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // Last transcript
        if !appState.currentTranscript.isEmpty {
            let transcriptItem = NSMenuItem(
                title: "Last: \(appState.currentTranscript)",
                action: nil,
                keyEquivalent: ""
            )
            transcriptItem.isEnabled = false
            transcriptItem.toolTip = appState.currentTranscript
            menu.addItem(transcriptItem)
            menu.addItem(.separator())
        }

        // Permissions status
        if !appState.hasAccessibilityPermission {
            let accItem = NSMenuItem(
                title: "⚠️ Grant Accessibility Permission...",
                action: #selector(MenuActionHandler.openAccessibilitySettings),
                keyEquivalent: ""
            )
            accItem.target = MenuActionHandler.shared
            menu.addItem(accItem)
        }

        if !appState.hasMicrophonePermission {
            let micItem = NSMenuItem(
                title: "🎤 Grant Microphone Permission...",
                action: #selector(MenuActionHandler.requestMicrophonePermission),
                keyEquivalent: ""
            )
            micItem.target = MenuActionHandler.shared
            menu.addItem(micItem)
        }

        if !appState.isApiKeyConfigured {
            let apiItem = NSMenuItem(
                title: "Configure OpenRouter API Key...",
                action: #selector(MenuActionHandler.openSettings),
                keyEquivalent: ""
            )
            apiItem.target = MenuActionHandler.shared
            menu.addItem(apiItem)
        }

        if !appState.hasAccessibilityPermission || !appState.hasMicrophonePermission || !appState.isApiKeyConfigured {
            menu.addItem(.separator())
        }

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(MenuActionHandler.openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = MenuActionHandler.shared
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Happy Whispr",
            action: #selector(MenuActionHandler.quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = MenuActionHandler.shared
        menu.addItem(quitItem)

        return menu
    }

    private static func statusText(for phase: AppPhase) -> String {
        switch phase {
        case .idle: return "Ready — hold ` to speak"
        case .pending: return "..."
        case .recording: return "🎤 Recording..."
        case .transcribing: return "⚡ Transcribing..."
        case .error(let error): return error.localizedDescription
        }
    }
}

// MARK: - Menu Action Handler

@MainActor
@objc final class MenuActionHandler: NSObject {
    static let shared = MenuActionHandler()

    var appState: AppState?
    var showSettings: (() -> Void)?

    @objc func openSettings() {
        showSettings?()
    }

    @objc func openAccessibilitySettings() {
        appState?.promptForAccessibilityPermission()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc func requestMicrophonePermission() {
        Task {
            let granted = await AudioCaptureService.requestPermission()
            await MainActor.run {
                appState?.hasMicrophonePermission = granted
            }
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
