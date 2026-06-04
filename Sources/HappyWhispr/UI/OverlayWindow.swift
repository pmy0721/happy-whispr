import SwiftUI
import AppKit

// MARK: - Overlay Window

final class OverlayWindow: NSPanel {

    private let appState: AppState

    // MARK: - Init

    init(
        appState: AppState,
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        self.appState = appState
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)

        configureWindow()
    }

    private func configureWindow() {
        // Visual properties
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        ignoresMouseEvents = true // Mouse passthrough
        isReleasedWhenClosed = false

        // Appearance
        appearance = NSAppearance(named: .vibrantDark)

        // Rounded corners via content view
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 20
        contentView?.layer?.cornerCurve = .continuous
        contentView?.layer?.masksToBounds = true

        // Frosted glass effect
        let visualEffect = NSVisualEffectView(frame: contentView?.bounds ?? .zero)
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 20
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
        visualEffect.autoresizingMask = [.width, .height]

        // Remove default content and add glass
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        contentView?.addSubview(visualEffect)

        // Add SwiftUI hosting view
        let hostingView = NSHostingView(rootView: OverlayContentView(appState: appState))
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = visualEffect.bounds
        visualEffect.addSubview(hostingView)
    }

    // MARK: - Show/Hide with Animation

    func show() {
        guard let screen = NSScreen.main else { return }

        let windowWidth: CGFloat = 400
        let windowHeight: CGFloat = 180
        let x = screen.frame.midX - windowWidth / 2
        let y = screen.frame.maxY - screen.visibleFrame.maxY - 60 // Below menu bar

        let targetFrame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)

        setFrame(targetFrame, display: true)
        alphaValue = 0
        setIsVisible(true)

        // Spring animation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            // Spring-like effect via timing
            self.animator().alphaValue = 1.0
        }
    }

    func dismiss(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.setIsVisible(false)
            completion?()
        })
    }

    // MARK: - Can Become Key

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay Content (SwiftUI)

struct OverlayContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            AudioWaveformView(rmsPower: appState.rmsPower)
                .frame(height: 64)
                .padding(.horizontal, 24)

            Spacer()

            Text(statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String {
        switch appState.phase {
        case .recording:
            return "正在录音，松开 ` 开始转写"
        case .transcribing:
            return "正在转写..."
        case .error(let error):
            return error.localizedDescription
        case .pending:
            return "准备录音..."
        case .idle:
            return appState.currentTranscript.isEmpty ? "按住 ` 录音" : appState.currentTranscript
        }
    }

    private var indicatorColor: Color {
        switch appState.phase {
        case .recording:
            return .red
        case .transcribing:
            return .blue
        case .error:
            return .orange
        default:
            return .white.opacity(0.7)
        }
    }
}

// MARK: - Audio Waveform View

struct AudioWaveformView: View {
    @State private var barLevels: [CGFloat] = Array(repeating: 0.35, count: 5)
    let rmsPower: Float

    private let baseHeights: [CGFloat] = [18, 34, 52, 34, 18]
    private let responseWeights: [CGFloat] = [0.58, 0.86, 1.15, 0.86, 0.58]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<barLevels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.525, green: 0.969, blue: 0.855),
                                Color(red: 0.204, green: 0.827, blue: 0.600),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(
                        width: 10,
                        height: max(10, baseHeights[index] * barLevels[index])
                    )
                    .shadow(
                        color: Color(red: 0.204, green: 0.827, blue: 0.600).opacity(0.45),
                        radius: 7,
                        x: 0,
                        y: 0
                    )
            }
        }
        .animation(.spring(response: 0.14, dampingFraction: 0.55), value: barLevels)
        .onChange(of: rmsPower) { _, newValue in
            updateWithRMS(newValue)
        }
    }

    private func updateWithRMS(_ rms: Float) {
        let amplified = min(max(CGFloat(rms) * 12.0, 0.0), 1.0)
        let shapedLevel = pow(amplified, 0.55)

        barLevels = responseWeights.enumerated().map { index, weight in
            let asymmetry = index.isMultiple(of: 2) ? 0.08 : -0.04
            return min(1.28, 0.42 + shapedLevel * weight + asymmetry * shapedLevel)
        }
    }
}
