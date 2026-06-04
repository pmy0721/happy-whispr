import Cocoa
import CoreGraphics

final class PasteService {

    /// Pastes the given text at the current cursor position in the foreground app.
    /// Uses NSPasteboard + synthesized Cmd+V keystroke.
    func paste(text: String) {
        guard !text.isEmpty else { return }

        // 1. Clear clipboard
        NSPasteboard.general.clearContents()

        // 2. Set text to clipboard
        NSPasteboard.general.setString(text, forType: .string)

        // Brief delay to ensure clipboard is flushed
        Thread.sleep(forTimeInterval: 0.01)

        // 3. Synthesize Cmd+V
        let source = CGEventSource(stateID: .combinedSessionState)

        let cmdKey = CGKeyCode(55) // kVK_Command
        let vKey = CGKeyCode(9)    // kVK_ANSI_V

        // Cmd key down
        if let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true) {
            cmdDown.flags = .maskCommand
            cmdDown.post(tap: .cghidEventTap)
        }

        // V key down with Cmd mask
        if let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: .cghidEventTap)
        }

        // V key up with Cmd mask
        if let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: .cghidEventTap)
        }

        // Cmd key up
        if let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) {
            cmdUp.post(tap: .cghidEventTap)
        }
    }
}
