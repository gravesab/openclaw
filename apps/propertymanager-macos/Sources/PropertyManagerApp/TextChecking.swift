import AppKit

/// SwiftUI has no spell-check switch on macOS, so the focused AppKit text view gets continuous
/// spelling and grammar checking. Automatic correction stays off so part numbers, URLs, and keys
/// are never rewritten.
@MainActor
enum TextChecking {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow,
                      let textView = window.firstResponder as? NSTextView,
                      textView.isEditable,
                      !textView.isContinuousSpellCheckingEnabled
                else { return }
                textView.isContinuousSpellCheckingEnabled = true
                textView.isGrammarCheckingEnabled = true
            }
        }
    }
}
