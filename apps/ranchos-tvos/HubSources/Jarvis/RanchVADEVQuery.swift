#if !os(tvOS)
import Foundation

enum RanchVADEVFilter: Equatable {
    case all
    case active
    case search(String)

    func apply(to tasks: [RanchOSPropertyLiveTask]) -> [RanchOSPropertyLiveTask] {
        let filtered = tasks.filter { task in
            switch self {
            case .all: true
            case .active: task.isActive
            case .search(let term):
                task.title.localizedCaseInsensitiveContains(term)
                || task.area.localizedCaseInsensitiveContains(term)
                || task.id.localizedCaseInsensitiveContains(term)
            }
        }
        return filtered.sorted { $0.id < $1.id }
    }

    static func parse(_ input: String) -> Self? {
        guard input.count <= 500 else { return nil }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
        switch text.lowercased() {
        case "show all tasks", "show property tasks": return .all
        case "show active tasks": return .active
        default:
            guard text.lowercased().hasPrefix("find ") else { return nil }
            let term = String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return term.isEmpty ? nil : .search(term)
        }
    }
}
#endif
