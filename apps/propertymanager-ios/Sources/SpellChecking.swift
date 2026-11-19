import SwiftUI
import UIKit

/// SwiftUI has no spell-check modifier. When a text box starts editing, turn on Apple's
/// UITextInput spell checking so misspellings get the system underline.
enum SpellChecking {
    private static var observers: [NSObjectProtocol] = []
    private static let lock = NSLock()

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard observers.isEmpty else { return }

        observers.append(NotificationCenter.default.addObserver(
            forName: UITextField.textDidBeginEditingNotification,
            object: nil,
            queue: .main
        ) { notification in
            enable(field: notification.object as? UITextField)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: UITextView.textDidBeginEditingNotification,
            object: nil,
            queue: .main
        ) { notification in
            enable(view: notification.object as? UITextView)
        })
    }

    private static func enable(field: UITextField?) {
        guard let field, !field.isSecureTextEntry else { return }
        if field.keyboardType == .URL || field.keyboardType == .decimalPad
            || field.keyboardType == .numberPad || field.keyboardType == .emailAddress
        {
            return
        }
        // Leave intentionally disabled fields alone (URLs, keys, part numbers).
        if field.autocorrectionType == .no { return }
        field.spellCheckingType = .yes
        field.autocorrectionType = .yes
    }

    private static func enable(view: UITextView?) {
        guard let view, !view.isSecureTextEntry else { return }
        if view.autocorrectionType == .no { return }
        view.spellCheckingType = .yes
        view.autocorrectionType = .yes
    }
}
