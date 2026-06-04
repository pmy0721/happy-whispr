import Cocoa
import CoreGraphics
import Combine

// MARK: - Keyboard Monitor State

enum KeyboardPhase: Equatable {
    case idle
    case pending
    case recording
}

// MARK: - Keyboard Monitor

final class KeyboardMonitor: ObservableObject {

    @Published var phase: KeyboardPhase = .idle

    // MARK: Constants

    private let backtickKeyCode: CGKeyCode = 50 // ANSI backtick/tilde key

    // MARK: Configuration

    var holdThresholdMs: Double = 200

    // MARK: State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdTimer: DispatchWorkItem?
    private var pendingKeyDownEvent: CGEvent?
    private var pendingKeyUpEvent: CGEvent?
    private var tapRetryCount = 0
    private let maxTapRetries = 3

    // MARK: - Public API

    func start() {
        guard eventTap == nil else { return }
        registerEventTap()
    }

    func stop() {
        disableEventTap()
        cancelHoldTimer()
        phase = .idle
    }

    // MARK: - Event Tap

    private func registerEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handleEvent(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            handleTapCreationFailure()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapRetryCount = 0
    }

    private func disableEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleTapCreationFailure() {
        tapRetryCount += 1
        if tapRetryCount <= maxTapRetries {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
                self?.registerEventTap()
            }
        }
    }

    // MARK: - Event Handling

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(backtickKeyCode) else {
            // Not backtick — pass through
            return Unmanaged.passRetained(event)
        }

        switch type {
        case .keyDown:
            return handleBacktickKeyDown(event: event)
        case .keyUp:
            return handleBacktickKeyUp(event: event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func handleBacktickKeyDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        switch phase {
        case .idle:
            // Enter pending state, start hold timer
            phase = .pending
            pendingKeyDownEvent = event

            let workItem = DispatchWorkItem { [weak self] in
                self?.holdTimerFired()
            }
            holdTimer = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Int(holdThresholdMs)),
                execute: workItem
            )
            // Swallow keyDown for now — we'll replay it if it turns out to be a tap
            return nil

        case .pending, .recording:
            // Ignore repeated keyDown
            return nil
        }
    }

    private func handleBacktickKeyUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        switch phase {
        case .pending:
            // keyUp arrived before timer → it's a tap, pass through
            cancelHoldTimer()
            pendingKeyUpEvent = event
            phase = .idle

            // Replay both keyDown and keyUp so system sees a normal backtick press
            if pendingKeyDownEvent != nil {
                CGEvent(keyboardEventSource: nil, virtualKey: backtickKeyCode, keyDown: true)?.post(tap: .cghidEventTap)
            }
            // Return the keyUp to be posted
            let result = Unmanaged.passRetained(event)
            pendingKeyDownEvent = nil
            pendingKeyUpEvent = nil
            return result

        case .recording:
            // Hold ended → stop recording
            phase = .idle
            cancelHoldTimer()
            // Notify that recording should stop (via phase change observation)
            return nil

        case .idle:
            // Shouldn't happen, but pass through
            return Unmanaged.passRetained(event)
        }
    }

    private func holdTimerFired() {
        guard phase == .pending else { return }
        phase = .recording
        // The pending keyDown was already swallowed — recording has begun
        // The AppState observer will call audioCapture.startCapture()
        pendingKeyDownEvent = nil
    }

    private func cancelHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    // MARK: - Tap Retry

    /// Called when CGEvent Tap is externally disabled (e.g., system sleep, permissions change)
    func handleTapDisabled() {
        disableEventTap()
        if tapRetryCount < maxTapRetries {
            tapRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
                self?.registerEventTap()
            }
        }
    }
}
