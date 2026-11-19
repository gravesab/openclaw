import AppKit

/// SwiftUI has no spell-check modifier on macOS. When any text box starts editing, turn on
/// Apple's continuous spelling and grammar checking on the field editor / text view.
/// Automatic correction stays off so part numbers, URLs, and keys are never rewritten.
enum TextChecking {
    private static var observers: [NSObjectProtocol] = []
    private static let lock = NSLock()

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard observers.isEmpty else { return }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSText.didBeginEditingNotification,
            object: nil,
            queue: .main
        ) { notification in
            enable(in: notification.object as? NSTextView)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            enable(in: window.firstResponder as? NSTextView)
            enable(in: window.fieldEditor(true, for: nil) as? NSTextView)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            enable(in: window.firstResponder as? NSTextView)
        })
    }

    private static func enable(in textView: NSTextView?) {
        guard let textView, textView.isEditable else { return }
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        // Red underlines while typing; do not auto-rewrite the text.
        textView.isAutomaticSpellingCorrectionEnabled = false
    }
}
