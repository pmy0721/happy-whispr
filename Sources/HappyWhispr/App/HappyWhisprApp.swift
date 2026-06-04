import SwiftUI
import AppKit
import Combine

// MARK: - App Entry

@main
struct HappyWhisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var overlayWindow: OverlayWindow?
    private var settingsWindowController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    let appState = AppState()

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        appState.checkPermissions()
        configureStatusBar()
        configureOverlayWindow()

        settingsWindowController = SettingsWindowController(appState: appState)

        MenuActionHandler.shared.appState = appState
        MenuActionHandler.shared.showSettings = { [weak self] in
            self?.settingsWindowController?.show()
        }

        appState.configureKeyboardMonitor()
        observePhase()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.keyboardMonitor.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState.checkPermissions()
    }

    // MARK: - Status Bar

    private func configureStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.imagePosition = .imageOnly
            button.title = ""
        }

        updateStatusIcon(phase: appState.phase)
        buildMenu()
    }

    private func buildMenu() {
        let menu = MenuBarView.buildMenu(
            appState: appState,
            showSettings: .constant(false),
            quitAction: { NSApp.terminate(nil) }
        )
        menu.delegate = self
        statusItem?.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        appState.checkPermissions()
    }

    // MARK: - Overlay Window

    private func configureOverlayWindow() {
        overlayWindow = OverlayWindow(
            appState: appState,
            contentRect: .zero,
            styleMask: [.fullSizeContentView, .titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    // MARK: - Phase Observation

    private func observePhase() {
        appState.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.handlePhaseChange(phase)
            }
            .store(in: &cancellables)

        Publishers.Merge3(
            appState.$hasAccessibilityPermission,
            appState.$hasMicrophonePermission,
            appState.$isApiKeyConfigured
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.buildMenu()
            }
            .store(in: &cancellables)
    }

    private func handlePhaseChange(_ phase: AppPhase) {
        updateStatusIcon(phase: phase)

        switch phase {
        case .recording:
            overlayWindow?.show()
            buildMenu()
        case .transcribing:
            buildMenu()
        case .idle:
            overlayWindow?.dismiss()
            buildMenu()
        case .pending:
            buildMenu()
        case .error:
            overlayWindow?.show()
            buildMenu()
        }
    }

    private func updateStatusIcon(phase: AppPhase) {
        guard let button = statusItem?.button else { return }

        button.image = MenuBarView.statusBarIcon()
        button.contentTintColor = phase == .idle || phase == .pending
            ? nil
            : MenuBarView.iconColor(for: phase)

        buildMenu()
    }
}
